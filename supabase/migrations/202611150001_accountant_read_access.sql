-- VITA Staff: accountant access and correct cash custody flow
-- Apply only after reviewing. Role helper functions remain unchanged.
-- Accountants receive read access to financial/request records and perform
-- operational cash actions only through SECURITY DEFINER RPCs.

ALTER TABLE public.vita_sales_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_requests_read ON public.vita_sales_requests;
CREATE POLICY vita_accountant_requests_read
  ON public.vita_sales_requests FOR SELECT TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_cash_collections ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_cash_collections_read ON public.vita_cash_collections;
CREATE POLICY vita_accountant_cash_collections_read
  ON public.vita_cash_collections FOR SELECT TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_finance_allocations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_allocations_read ON public.vita_finance_allocations;
CREATE POLICY vita_accountant_allocations_read
  ON public.vita_finance_allocations FOR SELECT TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_finance_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_finance_audit_read ON public.vita_finance_audit;
CREATE POLICY vita_accountant_finance_audit_read
  ON public.vita_finance_audit FOR SELECT TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_operations_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_operations_audit_read ON public.vita_operations_audit;
CREATE POLICY vita_accountant_operations_audit_read
  ON public.vita_operations_audit FOR SELECT TO authenticated
  USING (public.vita_is_accountant());

-- A handover to an accountant is a staff-to-staff transfer.
-- Only a separate handover made by the accountant to themselves is an office deposit.
CREATE OR REPLACE FUNCTION public.vita_sync_cash_custody_movement()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

  ELSIF NEW.movement_type = 'handed_over' AND NEW.recorded_by IS NOT NULL THEN
    SELECT role INTO v_receiver_role
    FROM public.vita_staff
    WHERE user_id = NEW.recorded_by AND active = true;

    IF NEW.recorded_by = NEW.staff_id AND v_receiver_role = 'accountant' THEN
      INSERT INTO public.vita_cash_custody_movements
        (source_movement_id, movement_type, from_staff_id, to_staff_id, amount, recorded_by, note, created_at)
      VALUES
        (NEW.id, 'office_receipt', NEW.staff_id, NULL, NEW.amount,
         NEW.recorded_by, NEW.note, NEW.created_at)
      ON CONFLICT (source_movement_id) DO NOTHING;

    ELSIF NEW.recorded_by <> NEW.staff_id THEN
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
$function$;

-- Accountant receives cash into their own custody balance, not directly into office cash.
CREATE OR REPLACE FUNCTION public.vita_accountant_receive_cash(
  p_staff_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_available numeric(12,2);
  v_staff_role text;
  v_id uuid;
BEGIN
  IF NOT public.vita_is_accountant() THEN
    RAISE EXCEPTION 'Доступно только бухгалтеру';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  SELECT role INTO v_staff_role
  FROM public.vita_staff
  WHERE user_id = p_staff_id AND active = true
  FOR UPDATE;

  IF NOT FOUND OR v_staff_role NOT IN ('sales','delivery') THEN
    RAISE EXCEPTION 'Выберите активного агента или доставщика';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || p_staff_id::text, 0));

  SELECT cash_on_hand INTO v_available
  FROM public.vita_cash_custody_balances
  WHERE staff_id = p_staff_id;

  IF COALESCE(v_available,0) < p_amount THEN
    RAISE EXCEPTION 'Недостаточно денег на руках. Доступно: %', COALESCE(v_available,0);
  END IF;

  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, recorded_by, note)
  VALUES
    (p_staff_id, 'handed_over', p_amount, auth.uid(),
     COALESCE(NULLIF(trim(p_note),''),'Передача денег бухгалтеру'))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Accountant deposits cash to the office only as a separate explicit operation.
CREATE OR REPLACE FUNCTION public.vita_accountant_deposit_to_office(
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
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

  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || auth.uid()::text, 0));

  SELECT cash_on_hand INTO v_available
  FROM public.vita_cash_custody_balances
  WHERE staff_id = auth.uid();

  IF COALESCE(v_available,0) < p_amount THEN
    RAISE EXCEPTION 'Недостаточно денег у бухгалтера. Доступно: %', COALESCE(v_available,0);
  END IF;

  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, recorded_by, note)
  VALUES
    (auth.uid(), 'handed_over', p_amount, auth.uid(),
     COALESCE(NULLIF(trim(p_note),''),'Сдано бухгалтером в кассу офиса'))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Money received by the accountant from a shop stays in accountant custody
-- until the separate office-deposit action is performed.
CREATE OR REPLACE FUNCTION public.vita_accountant_register_payment(
  p_shop_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL,
  p_due_date date DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_finance_id uuid;
BEGIN
  IF NOT public.vita_is_accountant() THEN
    RAISE EXCEPTION 'Доступно только бухгалтеру';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vita_shops WHERE id = p_shop_id AND active = true
  ) THEN
    RAISE EXCEPTION 'Магазин не найден или неактивен';
  END IF;

  INSERT INTO public.vita_shop_finances
    (shop_id, operation_type, amount, direction, payment_method, due_date, note, created_by, change_reason)
  VALUES
    (p_shop_id, 'payment', p_amount, 'credit', 'cash', p_due_date,
     COALESCE(NULLIF(trim(p_note),''),'Оплата принята бухгалтером'), auth.uid(),
     'Оплата принята бухгалтером')
  RETURNING id INTO v_finance_id;

  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, recorded_by, note)
  VALUES
    (auth.uid(), 'collected', p_amount, auth.uid(),
     COALESCE(NULLIF(trim(p_note),''),'Оплата магазина принята бухгалтером'));

  RETURN v_finance_id;
END;
$function$;

-- Accountant can confirm a pending cash collection, in addition to admin/delivery.
CREATE OR REPLACE FUNCTION public.vita_confirm_cash_collection(p_collection_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cash public.vita_cash_collections%ROWTYPE;
  v_finance_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;
  IF NOT (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR public.vita_staff_role() = 'delivery'
  ) THEN
    RAISE EXCEPTION 'Нет прав подтверждать деньги';
  END IF;

  SELECT * INTO v_cash
  FROM public.vita_cash_collections
  WHERE id = p_collection_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Запись о приёме денег не найдена';
  END IF;
  IF v_cash.status <> 'pending' THEN
    RAISE EXCEPTION 'Эта запись уже обработана';
  END IF;
  IF v_cash.order_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.vita_orders o
    WHERE o.id = v_cash.order_id AND o.shop_id = v_cash.shop_id
  ) THEN
    RAISE EXCEPTION 'Заказ не принадлежит этому магазину';
  END IF;

  INSERT INTO public.vita_shop_finances
    (shop_id, order_id, operation_type, amount, direction, payment_method, created_by, note, change_reason)
  VALUES
    (v_cash.shop_id, v_cash.order_id, 'payment', v_cash.amount, 'credit',
     v_cash.payment_method, auth.uid(), 'Подтверждение принятой оплаты',
     'Подтверждение денег сотрудника')
  RETURNING id INTO v_finance_id;

  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, cash_collection_id, recorded_by, note)
  VALUES
    (v_cash.received_by, 'collected', v_cash.amount, v_cash.id, auth.uid(),
     'Получение денег от магазина');

  UPDATE public.vita_cash_collections
  SET status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now()
  WHERE id = p_collection_id;

  RETURN v_finance_id;
END;
$function$;

-- Admin, accountant or delivery may receive cash from active agents/delivery staff.
-- The custody ledger is the source of truth for the available balance.
CREATE OR REPLACE FUNCTION public.vita_record_cash_handover(
  p_staff_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_actor_role text;
  v_staff_role text;
  v_balance numeric(12,2);
  v_id uuid;
BEGIN
  SELECT role INTO v_actor_role
  FROM public.vita_staff
  WHERE user_id = auth.uid() AND active = true;

  IF auth.uid() IS NULL OR COALESCE(v_actor_role,'') NOT IN ('admin','accountant','delivery') THEN
    RAISE EXCEPTION 'Нет прав принимать деньги';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  SELECT role INTO v_staff_role
  FROM public.vita_staff
  WHERE user_id = p_staff_id AND active = true
  FOR UPDATE;

  IF NOT FOUND OR v_staff_role NOT IN ('sales','delivery') THEN
    RAISE EXCEPTION 'Выберите активного агента или доставщика';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || p_staff_id::text, 0));

  SELECT cash_on_hand INTO v_balance
  FROM public.vita_cash_custody_balances
  WHERE staff_id = p_staff_id;

  IF p_amount > COALESCE(v_balance,0) THEN
    RAISE EXCEPTION 'Сумма превышает остаток денег у сотрудника';
  END IF;

  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, recorded_by, note)
  VALUES
    (p_staff_id, 'handed_over', p_amount, auth.uid(),
     COALESCE(NULLIF(trim(p_note),''),'Передача денег сотрудником'))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Allow accountants to record shop payments through the same audited flow.
CREATE OR REPLACE FUNCTION public.vita_record_shop_payment_by_staff(
  p_shop_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_role text;
  v_finance_id uuid;
  v_note text;
BEGIN
  SELECT role INTO v_role
  FROM public.vita_staff
  WHERE user_id = auth.uid() AND active = true;

  IF v_role IS NULL OR v_role NOT IN ('admin','delivery','accountant') THEN
    RAISE EXCEPTION 'Доступно только администратору, доставщику и бухгалтеру';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.vita_shops WHERE id = p_shop_id AND active = true
  ) THEN
    RAISE EXCEPTION 'Магазин не найден или неактивен';
  END IF;

  v_note := COALESCE(NULLIF(trim(p_note),''),'Оплата принята сотрудником');

  INSERT INTO public.vita_shop_finances
    (shop_id, operation_type, amount, direction, payment_method, note, created_by, change_reason)
  VALUES
    (p_shop_id, 'payment', p_amount, 'credit', 'cash', v_note, auth.uid(),
     'Оплата принята администратором, доставщиком или бухгалтером')
  RETURNING id INTO v_finance_id;

  INSERT INTO public.vita_staff_cash_movements
    (staff_id, movement_type, amount, recorded_by, note)
  VALUES
    (auth.uid(), 'collected', p_amount, auth.uid(), v_note);

  RETURN v_finance_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_accountant_deposit_to_office(numeric,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vita_accountant_deposit_to_office(numeric,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.vita_accountant_deposit_to_office(numeric,text) TO authenticated;

-- Existing date-filtered report RPC used by the accountant UI.
DO $$
DECLARE
  v_count integer;
  v_function_oid oid;
BEGIN
  SELECT count(*), (array_agg(p.oid))[1]
    INTO v_count, v_function_oid
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'vita_shop_activity_summary'
    AND p.prokind = 'f';

  IF v_count = 1 THEN
    -- regprocedure emits the exact callable signature using argument types only.
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION %s TO authenticated',
      v_function_oid::regprocedure
    );
  ELSIF v_count = 0 THEN
    RAISE EXCEPTION 'public.vita_shop_activity_summary() was not found; no EXECUTE grant applied';
  ELSE
    RAISE EXCEPTION 'Found % overloads of vita_shop_activity_summary(); inspect signatures before granting', v_count;
  END IF;
END
$$;

-- Accountants can also read overdue-debt rows through this security-invoker view.
CREATE OR REPLACE VIEW public.vita_overdue_debts
WITH (security_invoker = true)
AS
 SELECT f.id AS finance_id,
    f.shop_id,
    s.name AS shop_name,
    s.phone,
    s.address,
    s.sales_rep_id,
    f.due_date,
    f.amount - COALESCE(a.allocated_amount, 0::numeric) AS remaining_amount,
    CURRENT_DATE - f.due_date AS overdue_days
   FROM public.vita_shop_finances f
     JOIN public.vita_shops s ON s.id = f.shop_id
     LEFT JOIN (
       SELECT vita_finance_allocations.debit_finance_id,
              sum(vita_finance_allocations.amount) AS allocated_amount
         FROM public.vita_finance_allocations
        GROUP BY vita_finance_allocations.debit_finance_id
     ) a ON a.debit_finance_id = f.id
  WHERE (public.vita_is_admin() OR public.vita_is_accountant())
    AND f.direction = 'debit'::text
    AND f.due_date IS NOT NULL
    AND f.due_date <= (CURRENT_DATE - 7)
    AND (f.amount - COALESCE(a.allocated_amount, 0::numeric)) > 0::numeric;

-- Deliberately unchanged:
-- vita_is_accountant(), vita_is_admin(), vita_staff_role()
-- vita_complete_delivery_request() remains delivery-only.
