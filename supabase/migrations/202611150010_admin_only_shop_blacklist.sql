-- Shop activation/blacklisting is an administrator-only action.
-- Sales representatives may update their own shop contact details, but cannot
-- hide/restore a shop by changing its active flag.
DROP POLICY IF EXISTS shops_insert ON public.vita_shops;
CREATE POLICY shops_insert
  ON public.vita_shops FOR INSERT TO authenticated
  WITH CHECK (
    public.vita_is_admin()
    OR (
      sales_rep_id = auth.uid()
      AND public.vita_staff_role() = 'sales'
      AND public.vita_sales_zone_matches(zone_id)
    )
  );

DROP POLICY IF EXISTS shops_update ON public.vita_shops;
CREATE POLICY shops_update
  ON public.vita_shops FOR UPDATE TO authenticated
  USING (public.vita_is_admin() OR sales_rep_id = auth.uid())
  WITH CHECK (
    public.vita_is_admin()
    OR (
      sales_rep_id = auth.uid()
      AND public.vita_staff_role() = 'sales'
      AND public.vita_sales_zone_matches(zone_id)
    )
  );

CREATE OR REPLACE FUNCTION public.vita_guard_shop_status()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
BEGIN
  IF NEW.active IS DISTINCT FROM OLD.active
     AND NOT public.vita_is_admin() THEN
    RAISE EXCEPTION 'Перевод магазина в чёрный список и восстановление доступны только администратору';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_guard_shop_status() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS vita_guard_shop_status_trigger ON public.vita_shops;
CREATE TRIGGER vita_guard_shop_status_trigger
BEFORE UPDATE OF active ON public.vita_shops
FOR EACH ROW EXECUTE FUNCTION public.vita_guard_shop_status();
