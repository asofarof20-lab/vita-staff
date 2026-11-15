-- Cash custody transfers between staff and deposits to office are explicit,
-- balance-checked, actor-attributed ledger movements.
CREATE OR REPLACE FUNCTION public.vita_transfer_cash_to_staff(
  p_to_staff_id uuid,
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_target_role text;
  v_available numeric(12,2);
  v_id uuid;
  v_first text;
  v_second text;
BEGIN
  SELECT role INTO v_role
  FROM public.vita_staff
  WHERE user_id = auth.uid() AND active = true;

  IF auth.uid() IS NULL OR COALESCE(v_role,'') NOT IN ('admin','accountant','delivery') THEN
    RAISE EXCEPTION 'Нет прав передавать деньги сотрудникам';
  END IF;
  IF p_to_staff_id IS NULL OR p_to_staff_id = auth.uid() THEN
    RAISE EXCEPTION 'Выберите другого сотрудника';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  SELECT role INTO v_target_role
  FROM public.vita_staff
  WHERE user_id = p_to_staff_id AND active = true
  FOR UPDATE;

  IF NOT FOUND OR v_target_role NOT IN ('sales','delivery','accountant','admin') THEN
    RAISE EXCEPTION 'Получатель не найден или неактивен';
  END IF;

  v_first := LEAST(auth.uid()::text, p_to_staff_id::text);
  v_second := GREATEST(auth.uid()::text, p_to_staff_id::text);
  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || v_first, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || v_second, 0));

  SELECT cash_on_hand INTO v_available
  FROM public.vita_cash_custody_balances
  WHERE staff_id = auth.uid();

  IF COALESCE(v_available,0) < p_amount THEN
    RAISE EXCEPTION 'Недостаточно денег на руках. Доступно: %', COALESCE(v_available,0);
  END IF;

  INSERT INTO public.vita_cash_custody_movements
    (movement_type, from_staff_id, to_staff_id, amount, recorded_by, note)
  VALUES
    ('transfer', auth.uid(), p_to_staff_id, ROUND(p_amount,2), auth.uid(),
     COALESCE(NULLIF(trim(p_note),''),'Передача денег сотруднику'))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.vita_deposit_cash_to_office(
  p_amount numeric,
  p_note text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_available numeric(12,2);
  v_id uuid;
BEGIN
  SELECT role INTO v_role
  FROM public.vita_staff
  WHERE user_id = auth.uid() AND active = true;

  IF auth.uid() IS NULL OR COALESCE(v_role,'') NOT IN ('admin','accountant','delivery') THEN
    RAISE EXCEPTION 'Нет прав сдавать деньги в офисную кассу';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended('vita-cash-' || auth.uid()::text, 0));

  SELECT cash_on_hand INTO v_available
  FROM public.vita_cash_custody_balances
  WHERE staff_id = auth.uid();

  IF COALESCE(v_available,0) < p_amount THEN
    RAISE EXCEPTION 'Недостаточно денег на руках. Доступно: %', COALESCE(v_available,0);
  END IF;

  INSERT INTO public.vita_cash_custody_movements
    (movement_type, from_staff_id, to_staff_id, amount, recorded_by, note)
  VALUES
    ('office_receipt', auth.uid(), NULL, ROUND(p_amount,2), auth.uid(),
     COALESCE(NULLIF(trim(p_note),''),'Сдано в кассу офиса'))
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_transfer_cash_to_staff(uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_transfer_cash_to_staff(uuid,numeric,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vita_deposit_cash_to_office(numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_deposit_cash_to_office(numeric,text) TO authenticated;

DROP TRIGGER IF EXISTS vita_cash_custody_audit_trigger ON public.vita_cash_custody_movements;
CREATE TRIGGER vita_cash_custody_audit_trigger
AFTER INSERT OR UPDATE OR DELETE ON public.vita_cash_custody_movements
FOR EACH ROW EXECUTE FUNCTION public.vita_log_operations_audit();
