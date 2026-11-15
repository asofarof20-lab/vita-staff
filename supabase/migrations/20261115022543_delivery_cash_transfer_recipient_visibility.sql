CREATE POLICY vita_staff_delivery_cash_recipients_read
ON public.vita_staff
FOR SELECT
TO authenticated
USING (
  public.vita_staff_role() = 'delivery'
  AND active = true
  AND role IN ('admin', 'accountant')
);
