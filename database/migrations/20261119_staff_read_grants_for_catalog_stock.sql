-- VITANET QA-only migration.
-- The current staff UI reads these tables directly through Supabase PostgREST.
-- RLS policies already exist; grant SELECT only so those policies can be evaluated.
-- Do not apply to production until tested on an isolated Supabase branch and approved.

GRANT SELECT ON TABLE
  public.vita_order_items,
  public.vita_stock,
  public.vita_stock_movements,
  public.vita_stock_return_receipts
TO authenticated;
