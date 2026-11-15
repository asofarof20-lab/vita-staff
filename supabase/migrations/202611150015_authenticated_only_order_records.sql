-- These are authenticated VITA Staff order/payment records, not public catalog data.
-- Keep the existing row filters but remove the anonymous API role.
DROP POLICY IF EXISTS items_insert ON public.vita_order_items;
CREATE POLICY items_insert
  ON public.vita_order_items FOR INSERT TO authenticated
  WITH CHECK (
    public.vita_is_admin()
    OR EXISTS (
      SELECT 1 FROM public.vita_orders o
      WHERE o.id = vita_order_items.order_id
        AND o.sales_rep_id = auth.uid()
    )
  );

DROP POLICY IF EXISTS items_read ON public.vita_order_items;
CREATE POLICY items_read
  ON public.vita_order_items FOR SELECT TO authenticated
  USING (public.vita_can_access_order(order_id));

DROP POLICY IF EXISTS orders_insert ON public.vita_orders;
CREATE POLICY orders_insert
  ON public.vita_orders FOR INSERT TO authenticated
  WITH CHECK (
    public.vita_is_admin()
    OR (sales_rep_id = auth.uid() AND public.vita_staff_role() = 'sales')
  );

DROP POLICY IF EXISTS orders_read ON public.vita_orders;
CREATE POLICY orders_read
  ON public.vita_orders FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR sales_rep_id = auth.uid()
    OR delivery_id = auth.uid()
  );

DROP POLICY IF EXISTS orders_update ON public.vita_orders;
CREATE POLICY orders_update
  ON public.vita_orders FOR UPDATE TO authenticated
  USING (
    public.vita_is_admin()
    OR (delivery_id = auth.uid() AND public.vita_staff_role() = 'delivery')
  )
  WITH CHECK (
    public.vita_is_admin()
    OR (delivery_id = auth.uid() AND public.vita_staff_role() = 'delivery')
  );

DROP POLICY IF EXISTS payments_insert ON public.vita_payments;
CREATE POLICY payments_insert
  ON public.vita_payments FOR INSERT TO authenticated
  WITH CHECK (
    received_by = auth.uid()
    AND public.vita_can_access_order(order_id)
  );

DROP POLICY IF EXISTS payments_read ON public.vita_payments;
CREATE POLICY payments_read
  ON public.vita_payments FOR SELECT TO authenticated
  USING (public.vita_can_access_order(order_id));

DROP POLICY IF EXISTS returns_read ON public.vita_returns;
CREATE POLICY returns_read
  ON public.vita_returns FOR SELECT TO authenticated
  USING (public.vita_can_access_order(order_id));
