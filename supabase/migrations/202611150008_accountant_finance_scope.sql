-- Accountants may record real payments and financial returns, but may not
-- create arbitrary debt adjustments. Debt corrections remain admin/delivery only.
DROP POLICY IF EXISTS vita_shop_finances_accountant_insert ON public.vita_shop_finances;
CREATE POLICY vita_shop_finances_accountant_insert
  ON public.vita_shop_finances FOR INSERT TO authenticated
  WITH CHECK (
    public.vita_is_accountant()
    AND created_by = auth.uid()
    AND operation_type IN ('payment','return')
    AND direction = 'credit'
    AND amount > 0
  );
