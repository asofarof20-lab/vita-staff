DROP POLICY IF EXISTS vita_staff_delivery_cash_recipients_read ON public.vita_staff;
CREATE POLICY vita_staff_delivery_cash_recipients_read
ON public.vita_staff
FOR SELECT
TO authenticated
USING (
  (SELECT public.vita_staff_role()) = 'delivery'
  AND active = true
  AND role IN ('admin', 'accountant')
);
