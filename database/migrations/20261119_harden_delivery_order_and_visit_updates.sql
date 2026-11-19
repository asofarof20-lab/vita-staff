-- QA hardening: delivery staff must use audited RPCs for order state changes.
-- Admin remains the only role allowed to update vita_orders directly.
DROP POLICY IF EXISTS orders_update ON public.vita_orders;
DROP POLICY IF EXISTS orders_update_admin ON public.vita_orders;
CREATE POLICY orders_update_admin
ON public.vita_orders
FOR UPDATE
TO authenticated
USING (public.vita_is_admin())
WITH CHECK (public.vita_is_admin());

-- Delivery staff can read and update only their own shop-visit records.
DROP POLICY IF EXISTS visits_read ON public.vita_shop_visits;
CREATE POLICY visits_read
ON public.vita_shop_visits
FOR SELECT
TO authenticated
USING (
  public.vita_is_admin()
  OR (
    public.vita_staff_role() = 'delivery'
    AND delivery_id = auth.uid()
  )
  OR EXISTS (
    SELECT 1
    FROM public.vita_shops s
    WHERE s.id = vita_shop_visits.shop_id
      AND s.sales_rep_id = auth.uid()
  )
);

DROP POLICY IF EXISTS visits_update ON public.vita_shop_visits;
CREATE POLICY visits_update
ON public.vita_shop_visits
FOR UPDATE
TO authenticated
USING (
  public.vita_is_admin()
  OR (
    public.vita_staff_role() = 'delivery'
    AND delivery_id = auth.uid()
  )
)
WITH CHECK (
  public.vita_is_admin()
  OR (
    public.vita_staff_role() = 'delivery'
    AND delivery_id = auth.uid()
  )
);
