-- Avoid recursive RLS evaluation between shops and delivery assignments.
CREATE OR REPLACE FUNCTION public.vita_delivery_has_shop_access(p_shop_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM public.vita_shop_assignments a
    JOIN public.vita_staff s ON s.user_id = auth.uid()
    WHERE a.shop_id = p_shop_id
      AND a.delivery_id = auth.uid()
      AND a.active = true
      AND s.role = 'delivery'
      AND s.active = true
  );
$function$;

REVOKE ALL ON FUNCTION public.vita_delivery_has_shop_access(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_delivery_has_shop_access(uuid) TO authenticated;

DROP POLICY IF EXISTS shops_read ON public.vita_shops;
DROP POLICY IF EXISTS vita_shops_accountant_read ON public.vita_shops;
CREATE POLICY shops_read
  ON public.vita_shops FOR SELECT TO authenticated
  USING (
    public.vita_is_admin()
    OR public.vita_is_accountant()
    OR (
      public.vita_staff_role() = 'sales'
      AND sales_rep_id = auth.uid()
    )
    OR public.vita_delivery_has_shop_access(id)
  );
