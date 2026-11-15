-- VITANET security hardening: restrict helper and maintenance RPC execution.
-- Trigger functions remain callable by PostgreSQL triggers; they do not need
-- direct EXECUTE permission for API roles.

REVOKE ALL ON FUNCTION public.vita_run_overdue_check() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.vita_log_finance_changes() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.vita_set_sales_request_schedule() FROM PUBLIC, anon, authenticated;

-- These helpers are used by authenticated RLS policies and authenticated UI flows.
REVOKE ALL ON FUNCTION public.vita_can_access_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_can_access_order(uuid) TO authenticated;

REVOKE ALL ON FUNCTION public.vita_is_accountant() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_is_accountant() TO authenticated;

REVOKE ALL ON FUNCTION public.vita_is_admin() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_is_admin() TO authenticated;

REVOKE ALL ON FUNCTION public.vita_staff_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_staff_role() TO authenticated;

REVOKE ALL ON FUNCTION public.vita_sales_zone_matches(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_sales_zone_matches(uuid) TO authenticated;

-- Admin-only function remains available to signed-in users; its body enforces admin role.
REVOKE ALL ON FUNCTION public.vita_generate_overdue_notifications() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_generate_overdue_notifications() TO authenticated;

-- Admin-only zone assignment RPC; its body enforces admin role.
REVOKE ALL ON FUNCTION public.vita_assign_sales_rep_to_zone(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_assign_sales_rep_to_zone(uuid,uuid) TO authenticated;
