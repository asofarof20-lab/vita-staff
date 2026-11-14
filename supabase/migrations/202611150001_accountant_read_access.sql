-- VITA Staff: accountant read-only visibility
-- Apply in Supabase SQL Editor only after reviewing this migration.
-- This migration does NOT change role helper functions and grants no direct
-- INSERT, UPDATE, DELETE, or TRUNCATE privileges to accountants.

ALTER TABLE public.vita_sales_requests ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_requests_read ON public.vita_sales_requests;
CREATE POLICY vita_accountant_requests_read
  ON public.vita_sales_requests
  FOR SELECT
  TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_finance_allocations ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_allocations_read ON public.vita_finance_allocations;
CREATE POLICY vita_accountant_allocations_read
  ON public.vita_finance_allocations
  FOR SELECT
  TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_finance_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_finance_audit_read ON public.vita_finance_audit;
CREATE POLICY vita_accountant_finance_audit_read
  ON public.vita_finance_audit
  FOR SELECT
  TO authenticated
  USING (public.vita_is_accountant());

ALTER TABLE public.vita_operations_audit ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS vita_accountant_operations_audit_read ON public.vita_operations_audit;
CREATE POLICY vita_accountant_operations_audit_read
  ON public.vita_operations_audit
  FOR SELECT
  TO authenticated
  USING (public.vita_is_accountant());

-- The current UI calls vita_shop_activity_summary() for date-filtered payment
-- and return summaries. Grant EXECUTE only if exactly one public overload
-- exists; fail safely if the database has an unexpected overloaded function.
DO $$
DECLARE
  v_count integer;
  v_signature text;
BEGIN
  SELECT count(*), min(pg_get_function_identity_arguments(p.oid))
    INTO v_count, v_signature
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'vita_shop_activity_summary'
    AND p.prokind = 'f';

  IF v_count = 1 THEN
    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION public.vita_shop_activity_summary(%s) TO authenticated',
      v_signature
    );
  ELSIF v_count = 0 THEN
    RAISE EXCEPTION 'public.vita_shop_activity_summary() was not found; no EXECUTE grant applied';
  ELSE
    RAISE EXCEPTION 'Found % overloads of vita_shop_activity_summary(); inspect signatures before granting', v_count;
  END IF;
END
$$;

-- Deliberately unchanged:
-- vita_is_accountant(), vita_is_admin(), vita_staff_role()
-- vita_complete_delivery_request() remains delivery-only.
