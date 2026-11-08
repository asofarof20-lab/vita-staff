-- VITA Staff: accountant role and cash custody ledger
-- Additive migration: keeps existing shops, orders, products and finance history intact.

BEGIN;

-- 1) Allow the new accountant role while preserving the existing three roles.
DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.vita_staff'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%role%'
  LOOP
    EXECUTE format('ALTER TABLE public.vita_staff DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;

ALTER TABLE public.vita_staff
  ADD CONSTRAINT vita_staff_role_check
  CHECK (role IN ('admin','sales','delivery','accountant'));

CREATE OR REPLACE FUNCTION public.vita_is_accountant()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.vita_staff
    WHERE user_id = auth.uid()
      AND role = 'accountant'
      AND active = true
  );
$$;

-- 2) Append-only custody ledger. NULL destination means office cash register.
CREATE TABLE IF NOT EXISTS public.vita_cash_custody_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  source_movement_id uuid UNIQUE REFERENCES public.vita_staff_cash_movements(id),
  movement_type text NOT NULL
    CHECK (movement_type IN ('collection','transfer','office_receipt')),
  from_staff_id uuid REFERENCES public.vita_staff(user_id),
  to_staff_id uuid REFERENCES public.vita_staff(user_id),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  recorded_by uuid NOT NULL REFERENCES public.vita_staff(user_id),
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT vita_cash_custody_parties_check CHECK (
    (movement_type = 'collection' AND from_staff_id IS NULL AND to_staff_id IS NOT NULL)
    OR
    (movement_type = 'transfer' AND from_staff_id IS NOT NULL AND to_staff_id IS NOT NULL AND from_staff_id <> to_staff_id)
    OR
    (movement_type = 'office_receipt' AND from_staff_id IS NOT NULL AND to_staff_id IS NULL)
  )
);

-- 3) Bring the existing cash history into the new ledger exactly once.
INSERT INTO public.vita_cash_custody_movements
  (source_movement_id, movement_type, from_staff_id, to_staff_id, amount, recorded_by, note, created_at)
SELECT
  m.id,
  CASE WHEN m.movement_type = 'collected' THEN 'collection' ELSE 'transfer' END,
  CASE WHEN m.movement_type = 'collected' THEN NULL ELSE m.staff_id END,
  CASE WHEN m.movement_type = 'collected' THEN m.staff_id ELSE m.recorded_by END,
  m.amount,
  COALESCE(m.recorded_by, m.staff_id),
  m.note,
  m.created_at
FROM public.vita_staff_cash_movements m
WHERE m.movement_type IN ('collected','handed_over')
  AND (m.movement_type = 'collected' OR (m.recorded_by IS NOT NULL AND m.recorded_by <> m.staff_id))
ON CONFLICT (source_movement_id) DO NOTHING;

-- Mirror future collections and handovers into the custody ledger.
CREATE OR REPLACE FUNCTION public.vita_sync_cash_custody_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_receiver_role text;
BEGIN
  IF NEW.movement_type = 'collected' THEN
    INSERT INTO public.vita_cash_custody_movements
      (source_movement_id, movement_type, from_staff_id, to_staff_id, amount, recorded_by, note, created_at)
    VALUES
      (NEW.id, 'collection', NULL, NEW.staff_id, NEW.amount,
       COALESCE(NEW.recorded_by, NEW.staff_id), NEW.note, NEW.created_at)
    ON CONFLICT (source_movement_id) DO NOTHING;
  ELSIF NEW.movement_type = 'handed_over'
        AND NEW.recorded_by IS NOT NULL
        AND NEW.recorded_by <> NEW.staff_id THEN
    SELECT role INTO v_receiver_role
    FROM public.vita_staff
    WHERE user_id = NEW.recorded_by AND active = true;

    IF v_receiver_role = 'accountant' THEN
      -- Accountant receipt moves the cash out of the employee's balance
      -- and into the office register, not into the accountant's personal balance.
      INSERT INTO public.vita_cash_custody_movements
        (source_movement_id, movement_type, from_staff_id, to_staff_id, amount, recorded_by, note, created_at)
      VALUES
        (NEW.id, 'office_receipt', NEW.staff_id, NULL, NEW.amount,
         NEW.recorded_by, NEW.note, NEW.created_at)
      ON CONFLICT (source_movement_id) DO NOTHING;
    ELSE
      -- Existing admin handover reduces the sender and credits the admin.
      INSERT INTO public.vita_cash_custody_movements
        (source_movement_id, movement_type, from_staff_id, to_staff_id, amount, recorded_by, note, created_at)
      VALUES
        (NEW.id, 'transfer', NEW.staff_id, NEW.recorded_by, NEW.amount,
         NEW.recorded_by, NEW.note, NEW.created_at)
      ON CONFLICT (source_movement_id) DO NOTHING;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS vita_sync_cash_custody_movement ON public.vita_staff_cash_movements;
CREATE TRIGGER vita_sync_cash_custody_movement
AFTER INSERT ON public.vita_staff_cash_movements
FOR EACH ROW EXECUTE FUNCTION public.vita_sync_cash_custody_movement();

-- 4) Balances include all active staff, including admin and delivery.
CREATE OR REPLACE VIEW public.vita_cash_custody_balances
WITH (security_invoker = true)
AS
SELECT
  s.user_id AS staff_id,
  s.full_name,
  s.role,
  COALESCE(SUM(CASE WHEN c.movement_type = 'collection' AND c.to_staff_id = s.user_id THEN c.amount ELSE 0 END),0)::numeric(12,2) AS total_collected,
  COALESCE(SUM(CASE WHEN c.from_staff_id = s.user_id THEN c.amount ELSE 0 END),0)::numeric(12,2) AS total_handed_over,
  COALESCE(SUM(CASE WHEN c.to_staff_id = s.user_id THEN c.amount WHEN c.from_staff_id = s.user_id THEN -c.amount ELSE 0 END),0)::numeric(12,2) AS cash_on_hand
FROM public.vita_staff s
LEFT JOIN public.vita_cash_custody_movements c
  ON c.to_staff_id = s.user_id OR c.from_staff_id = s.user_id
WHERE s.active = true
GROUP BY s.user_id, s.full_name, s.role;

CREATE OR REPLACE VIEW public.vita_cash_office_balance
WITH (security_invoker = true)
AS
SELECT COALESCE(SUM(amount),0)::numeric(12,2) AS office_cash
FROM public.vita_cash_custody_movements
WHERE movement_type = 'office_receipt';

GRANT SELECT ON public.vita_cash_custody_movements TO authenticated;
GRANT SELECT ON public.vita_cash_custody_balances TO authenticated;
GRANT SELECT ON public.vita_cash_office_balance TO authenticated;

ALTER TABLE public.vita_cash_custody_movements ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_cash_custody_read_finance_roles ON public.vita_cash_custody_movements;
CREATE POLICY vita_cash_custody_read_finance_roles
ON public.vita_cash_custody_movements
FOR SELECT TO authenticated
USING (public.vita_is_admin() OR public.vita_is_accountant());

-- Accountant can read employee names/roles and existing cash history, but cannot edit staff.
DROP POLICY IF EXISTS staff_read ON public.vita_staff;
CREATE POLICY staff_read
ON public.vita_staff
FOR SELECT TO authenticated
USING (user_id = auth.uid() OR public.vita_is_admin() OR public.vita_is_accountant());

DROP POLICY IF EXISTS vita_staff_cash_movements_accountant_read ON public.vita_staff_cash_movements;
CREATE POLICY vita_staff_cash_movements_accountant_read
ON public.vita_staff_cash_movements
FOR SELECT TO authenticated
USING (public.vita_is_accountant());

-- Accountant can see all shops and their financial history, but cannot edit shop profiles.
DROP POLICY IF EXISTS vita_shops_accountant_read ON public.vita_shops;
CREATE POLICY vita_shops_accountant_read
ON public.vita_shops
FOR SELECT TO authenticated
USING (public.vita_is_accountant());

DROP POLICY IF EXISTS vita_shop_finances_accountant_read ON public.vita_shop_finances;
CREATE POLICY vita_shop_finances_accountant_read
ON public.vita_shop_finances
FOR SELECT TO authenticated
USING (public.vita_is_accountant());

-- Accountant may register incoming payments or credit adjustments to close debts.
-- No sales, returns, arbitrary debits, updates or deletes are granted.
DROP POLICY IF EXISTS vita_shop_finances_accountant_insert ON public.vita_shop_finances;
CREATE POLICY vita_shop_finances_accountant_insert
ON public.vita_shop_finances
FOR INSERT TO authenticated
WITH CHECK (
  public.vita_is_accountant()
  AND created_by = auth.uid()
  AND operation_type IN ('payment','adjustment')
  AND direction = 'credit'
  AND amount > 0
);

DROP POLICY IF EXISTS vita_returns_accountant_read ON public.vita_returns;
CREATE POLICY vita_returns_accountant_read
ON public.vita_returns
FOR SELECT TO authenticated
USING (public.vita_is_accountant());

-- 5) Accountant receipt: deduct from the employee's custody and add to office cash.
CREATE OR REPLACE FUNCTION public.vita_accountant_receive_cash(
  p_staff_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_available numeric(12,2);
  v_id uuid;
BEGIN
  IF NOT public.vita_is_accountant() THEN
    RAISE EXCEPTION 'Доступно только бухгалтеру';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vita_staff
    WHERE user_id = p_staff_id AND active = true
  ) THEN
    RAISE EXCEPTION 'Сотрудник не найден или неактивен';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || p_staff_id::text, 0));

  SELECT cash_on_hand INTO v_available
  FROM public.vita_cash_custody_balances
  WHERE staff_id = p_staff_id;

  IF COALESCE(v_available,0) < p_amount THEN
    RAISE EXCEPTION 'Недостаточно денег на руках. Доступно: %', COALESCE(v_available,0);
  END IF;

  -- Insert into the existing audited cash-movement table. Its trigger mirrors
  -- this handover into the custody ledger and the old balance view subtracts it.
  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, recorded_by, note)
  VALUES
    (p_staff_id, 'handed_over', p_amount, auth.uid(), NULLIF(trim(p_note),''))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.vita_accountant_receive_cash(uuid,numeric,text) TO authenticated;

COMMIT;
