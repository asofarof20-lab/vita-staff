CREATE OR REPLACE FUNCTION public.vita_receive_catalog_return(
  p_order_id uuid,
  p_product_code text,
  p_product_name text,
  p_quantity numeric,
  p_reason text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_id uuid;
  v_status text;
  v_ordered numeric;
  v_returned numeric;
  v_code text;
  v_name text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Необходимо войти в систему';
  END IF;

  IF NOT (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR public.vita_staff_role() = 'delivery'
  ) THEN
    RAISE EXCEPTION 'Принять возврат может администратор, бухгалтер или доставщик';
  END IF;

  v_code := NULLIF(trim(COALESCE(p_product_code, '')), '');
  v_name := COALESCE(NULLIF(trim(COALESCE(p_product_name, '')), ''), v_code);

  IF p_quantity IS NULL OR p_quantity <= 0 OR v_code IS NULL THEN
    RAISE EXCEPTION 'Укажите код товара и количество больше нуля';
  END IF;

  SELECT status INTO v_status
  FROM public.vita_orders
  WHERE id = p_order_id AND source = 'catalog'
  FOR UPDATE;

  IF NOT FOUND OR v_status NOT IN ('confirmed', 'delivered') THEN
    RAISE EXCEPTION 'Принять возврат можно только по подтверждённому или доставленному заказу';
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
$$;

REVOKE ALL ON FUNCTION public.vita_receive_catalog_return(uuid, text, text, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_receive_catalog_return(uuid, text, text, numeric, text) TO authenticated;
