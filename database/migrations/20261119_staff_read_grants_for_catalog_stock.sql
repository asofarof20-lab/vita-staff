-- VITANET QA-only migration.
-- Apply only on an isolated Supabase development branch.
-- Existing RLS policies remain enabled; this migration grants SELECT only
-- for staff UI reads and extends guarded staff RPCs.
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

-- A delivery worker may receive a catalog return only for an order assigned to them.
-- Admin and accountant retain their all-store operational authority.
CREATE OR REPLACE FUNCTION public.vita_receive_catalog_return(
  p_order_id uuid,
  p_product_code text,
  p_product_name text,
  p_quantity numeric,
  p_reason text DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_id uuid;
  v_status text;
  v_delivery_id uuid;
  v_role text;
  v_ordered numeric;
  v_returned numeric;
  v_code text;
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  v_role := public.vita_staff_role();
  IF COALESCE(v_role,'') NOT IN ('admin','accountant','delivery') THEN
    RAISE EXCEPTION 'Принять возврат может администратор, бухгалтер или доставщик';
  END IF;

  v_code := NULLIF(trim(COALESCE(p_product_code, '')), '');
  v_name := COALESCE(NULLIF(trim(COALESCE(p_product_name, '')), ''), v_code);
  IF p_quantity IS NULL OR p_quantity <= 0 OR v_code IS NULL THEN
    RAISE EXCEPTION 'Укажите код товара и количество больше нуля';
  END IF;

  SELECT status, delivery_id
  INTO v_status, v_delivery_id
  FROM public.vita_orders
  WHERE id = p_order_id AND source = 'catalog'
  FOR UPDATE;

  IF NOT FOUND OR v_status NOT IN ('confirmed', 'delivered') THEN
    RAISE EXCEPTION 'Принять возврат можно только по подтверждённому или доставленному заказу';
  END IF;

  IF v_role = 'delivery' AND v_delivery_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Доставщик может оформить возврат только по назначенному ему заказу';
  END IF;

  SELECT COALESCE(sum(quantity), 0)
  INTO v_ordered
  FROM public.vita_order_items
  WHERE order_id = p_order_id AND product_code = v_code;

  SELECT COALESCE(sum(quantity), 0)
  INTO v_returned
  FROM public.vita_stock_return_receipts
  WHERE order_id = p_order_id AND product_code = v_code;

  IF v_ordered = 0 THEN
    RAISE EXCEPTION 'Этот товар не найден в заказе';
  END IF;
  IF v_returned + p_quantity > v_ordered THEN
    RAISE EXCEPTION 'Возврат превышает количество товара в заказе';
  END IF;

  INSERT INTO public.vita_stock_return_receipts
    (order_id, product_code, product_name, quantity, reason, received_by)
  VALUES
    (p_order_id, v_code, v_name, p_quantity, NULLIF(trim(COALESCE(p_reason, '')), ''), auth.uid())
  RETURNING id INTO v_id;

  INSERT INTO public.vita_stock(product_code, product_name, quantity, updated_by)
  VALUES (v_code, v_name, p_quantity, auth.uid())
  ON CONFLICT (product_code) DO UPDATE
    SET product_name = COALESCE(EXCLUDED.product_name, public.vita_stock.product_name),
        quantity = public.vita_stock.quantity + EXCLUDED.quantity,
        updated_at = now(),
        updated_by = auth.uid();

  INSERT INTO public.vita_stock_movements
    (product_code, product_name, movement_type, quantity, order_id, note, created_by)
  VALUES
    (v_code, v_name, 'return', p_quantity, p_order_id,
     NULLIF(trim(COALESCE(p_reason, '')), ''), auth.uid());

  RETURN v_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_receive_catalog_return(uuid,text,text,numeric,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_receive_catalog_return(uuid,text,text,numeric,text) TO authenticated;

-- Prevent accidental use of the legacy bulk initializer that creates fictional 1000-unit balances.
REVOKE ALL ON FUNCTION public.vita_stock_seed_catalog(jsonb,numeric) FROM PUBLIC, anon, authenticated;


-- Reject malformed catalog order lines before any warehouse deduction.
-- product_code is nullable in the legacy table; silently skipping such a line
-- would otherwise confirm an order without decrementing all of its products.
CREATE OR REPLACE FUNCTION public.vita_confirm_catalog_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_item record;
  v_old_status text;
  v_shop_id uuid;
BEGIN
  IF NOT public.vita_is_admin() THEN
    RAISE EXCEPTION 'Подтвердить заказ может только администратор';
  END IF;

  SELECT status, shop_id INTO v_old_status, v_shop_id
  FROM public.vita_orders
  WHERE id = p_order_id AND source = 'catalog'
  FOR UPDATE;

  IF NOT FOUND OR v_old_status <> 'new' THEN
    RAISE EXCEPTION 'Заказ не найден или уже обработан';
  END IF;
  IF v_shop_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.vita_shops WHERE id = v_shop_id AND active = true
  ) THEN
    RAISE EXCEPTION 'Сначала прикрепите действующий магазин к заказу';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.vita_order_items WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'В заказе нет товаров';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM public.vita_order_items
    WHERE order_id = p_order_id
      AND (NULLIF(trim(product_code), '') IS NULL OR quantity IS NULL OR quantity <= 0)
  ) THEN
    RAISE EXCEPTION 'В заказе есть товар без кода или с некорректным количеством. Исправьте состав заказа до подтверждения';
  END IF;

  FOR v_item IN
    SELECT product_code, max(product_name) AS product_name, sum(quantity) AS qty
    FROM public.vita_order_items
    WHERE order_id = p_order_id
    GROUP BY product_code
    ORDER BY product_code
  LOOP
    INSERT INTO public.vita_stock(product_code, product_name, quantity)
    VALUES (v_item.product_code, v_item.product_name, 0)
    ON CONFLICT (product_code) DO UPDATE
      SET product_name = COALESCE(EXCLUDED.product_name, public.vita_stock.product_name);

    PERFORM 1
    FROM public.vita_stock
    WHERE product_code = v_item.product_code AND quantity >= v_item.qty
    FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Недостаточно товара на складе: %', v_item.product_code;
    END IF;
  END LOOP;

  FOR v_item IN
    SELECT product_code, max(product_name) AS product_name, sum(quantity) AS qty
    FROM public.vita_order_items
    WHERE order_id = p_order_id
    GROUP BY product_code
    ORDER BY product_code
  LOOP
    UPDATE public.vita_stock
    SET quantity = quantity - v_item.qty,
        product_name = COALESCE(v_item.product_name, product_name),
        updated_at = now(),
        updated_by = auth.uid()
    WHERE product_code = v_item.product_code;

    INSERT INTO public.vita_stock_movements
      (product_code, product_name, movement_type, quantity, order_id, note, created_by)
    VALUES
      (v_item.product_code, v_item.product_name, 'sale', v_item.qty, p_order_id,
       'Списание по подтверждённому заказу', auth.uid());
  END LOOP;

  UPDATE public.vita_orders
  SET status = 'confirmed', confirmed_by = auth.uid(), confirmed_at = now()
  WHERE id = p_order_id;

  INSERT INTO public.vita_order_audit(order_id, action, old_status, new_status, actor_id)
  VALUES (p_order_id, 'confirmed', v_old_status, 'confirmed', auth.uid());
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_confirm_catalog_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_confirm_catalog_order(uuid) TO authenticated;
