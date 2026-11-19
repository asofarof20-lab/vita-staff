-- VITANET QA-only migration.
-- Apply only on an isolated Supabase development branch.
-- Existing RLS policies remain enabled; this migration grants SELECT only
-- for staff UI reads and extends the guarded adjustment RPC to accountants.
-- Do not apply to production until tested and explicitly approved.

GRANT SELECT ON TABLE
  public.vita_order_items,
  public.vita_stock,
  public.vita_stock_movements,
  public.vita_stock_return_receipts
TO authenticated;

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

  IF auth.uid() IS NULL OR COALESCE(v_role,'') NOT IN ('admin','delivery','accountant') THEN
    RAISE EXCEPTION 'Корректировка долга доступна только администратору, доставщику и бухгалтеру';
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
  IF NOT EXISTS (
    SELECT 1 FROM public.vita_shops WHERE id=p_shop_id AND active=true
  ) THEN
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

REVOKE ALL ON FUNCTION public.vita_record_shop_adjustment_by_staff(uuid,numeric,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_record_shop_adjustment_by_staff(uuid,numeric,text,text) TO authenticated;
