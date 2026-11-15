-- Give delivery staff the cross-shop cash custody visibility and receipt actions
-- explicitly required for operational money handling. Only active sales/delivery
-- staff rows are visible to delivery staff; admin/accountant rules remain unchanged.

DROP POLICY IF EXISTS vita_staff_cash_roles_read ON public.vita_staff;
CREATE POLICY vita_staff_cash_roles_read
  ON public.vita_staff FOR SELECT TO authenticated
  USING (
    public.vita_staff_role() = 'delivery'
    AND active = true
    AND role IN ('sales','delivery')
  );

DROP POLICY IF EXISTS vita_cash_custody_read_finance_roles ON public.vita_cash_custody_movements;
CREATE POLICY vita_cash_custody_read_finance_roles
  ON public.vita_cash_custody_movements FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR public.vita_staff_role() = 'delivery'
  );

DROP POLICY IF EXISTS vita_staff_cash_movements_delivery_read ON public.vita_staff_cash_movements;
CREATE POLICY vita_staff_cash_movements_delivery_read
  ON public.vita_staff_cash_movements FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR public.vita_staff_role() = 'delivery'
  );
