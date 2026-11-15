-- Delivery staff need all-shop visibility for financial work; delivery requests
-- remain restricted to the assigned delivery_id by vita_sales_requests RLS.
DROP POLICY IF EXISTS shops_read ON public.vita_shops;
CREATE POLICY shops_read
  ON public.vita_shops FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR public.vita_staff_role() = 'delivery'
    OR (public.vita_staff_role() = 'sales' AND sales_rep_id = auth.uid())
  );

DROP POLICY IF EXISTS "vita finance read" ON public.vita_shop_finances;
CREATE POLICY "vita finance read"
  ON public.vita_shop_finances FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR public.vita_staff_role() = 'delivery'
    OR EXISTS (
      SELECT 1 FROM public.vita_shops s
      WHERE s.id = vita_shop_finances.shop_id
        AND s.sales_rep_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS vita_allocations_read ON public.vita_finance_allocations;
CREATE POLICY vita_allocations_read
  ON public.vita_finance_allocations FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_staff_role() = 'delivery'
    OR EXISTS (
      SELECT 1 FROM public.vita_shop_finances f
      JOIN public.vita_shops s ON s.id = f.shop_id
      WHERE f.id = vita_finance_allocations.debit_finance_id
        AND s.sales_rep_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS "vita finance audit role read" ON public.vita_finance_audit;
CREATE POLICY "vita finance audit role read"
  ON public.vita_finance_audit FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_staff_role() = 'delivery'
    OR EXISTS (
      SELECT 1 FROM public.vita_shops s
      WHERE s.id = vita_finance_audit.shop_id
        AND s.sales_rep_id = auth.uid()
    )
  );

-- Financial adjustments are append-only entries. Only admin and delivery may
-- increase/decrease debt; sales and accountants cannot use this endpoint.
CREATE OR REPLACE FUNCTION public.vita_record_shop_adjustment_by_staff(
  p_shop_id uuid,
  p_amount numeric,
  p_direction text,
  p_note text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_id uuid;
  v_reason text;
BEGIN
  SELECT role INTO v_role
  FROM public.vita_staff
  WHERE user_id = auth.uid() AND active = true;

  IF auth.uid() IS NULL OR COALESCE(v_role,'') NOT IN ('admin','delivery') THEN
    RAISE EXCEPTION 'Корректировка долга доступна только администратору и доставщику';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;
  IF p_direction NOT IN ('debit','credit') THEN
    RAISE EXCEPTION 'Укажите увеличение или уменьшение долга';
  END IF;
  v_reason := NULLIF(trim(COALESCE(p_note,'')),'');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Укажите причину корректировки';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vita_shops WHERE id=p_shop_id AND active=true) THEN
    RAISE EXCEPTION 'Магазин не найден или неактивен';
  END IF;

  INSERT INTO public.vita_shop_finances
    (shop_id, operation_type, amount, direction, note, created_by, change_reason)
  VALUES
    (p_shop_id, 'adjustment', ROUND(p_amount,2), p_direction, v_reason, auth.uid(), v_reason)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

-- Financial returns are recorded by admin, delivery or accountant as a credit.
CREATE OR REPLACE FUNCTION public.vita_record_shop_return_by_staff(
  p_shop_id uuid,
  p_amount numeric,
  p_note text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_role text;
  v_id uuid;
  v_reason text;
BEGIN
  SELECT role INTO v_role
  FROM public.vita_staff
  WHERE user_id = auth.uid() AND active = true;

  IF auth.uid() IS NULL OR COALESCE(v_role,'') NOT IN ('admin','delivery','accountant') THEN
    RAISE EXCEPTION 'Финансовый возврат доступен администратору, доставщику и бухгалтеру';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Сумма должна быть больше нуля';
  END IF;
  v_reason := NULLIF(trim(COALESCE(p_note,'')),'');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Укажите причину финансового возврата';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vita_shops WHERE id=p_shop_id AND active=true) THEN
    RAISE EXCEPTION 'Магазин не найден или неактивен';
  END IF;

  INSERT INTO public.vita_shop_finances
    (shop_id, operation_type, amount, direction, note, created_by, change_reason)
  VALUES
    (p_shop_id, 'return', ROUND(p_amount,2), 'credit', v_reason, auth.uid(), v_reason)
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_record_shop_adjustment_by_staff(uuid,numeric,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_record_shop_adjustment_by_staff(uuid,numeric,text,text) TO authenticated;
REVOKE ALL ON FUNCTION public.vita_record_shop_return_by_staff(uuid,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_record_shop_return_by_staff(uuid,numeric,text) TO authenticated;
