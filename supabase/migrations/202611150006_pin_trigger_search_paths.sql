-- VITANET: close direct API access to the DDL event-trigger function and
-- pin the request-scheduling trigger to a trusted search_path.

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;

ALTER FUNCTION public.vita_set_sales_request_schedule()
  SET search_path = pg_catalog, public, pg_temp;
