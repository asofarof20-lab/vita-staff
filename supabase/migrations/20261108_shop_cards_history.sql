-- VITA Staff: scalable per-shop financial summaries and indexed history
-- Additive only: no existing finance, shop, product or order rows are changed.

BEGIN;

CREATE INDEX IF NOT EXISTS vita_shop_finances_shop_created_idx
  ON public.vita_shop_finances (shop_id, created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS vita_shop_finances_created_idx
  ON public.vita_shop_finances (created_at DESC, id DESC);

CREATE INDEX IF NOT EXISTS vita_shop_finances_operation_created_idx
  ON public.vita_shop_finances (operation_type, created_at DESC, id DESC, shop_id);

CREATE OR REPLACE VIEW public.vita_shop_finance_summary
WITH (security_invoker = true)
AS
SELECT
  s.id AS shop_id,
  COALESCE(SUM(f.amount) FILTER (WHERE f.operation_type = 'sale'), 0)::numeric(14,2) AS total_ordered,
  COALESCE(SUM(f.amount) FILTER (WHERE f.operation_type = 'payment'), 0)::numeric(14,2) AS total_paid,
  COALESCE(SUM(f.amount) FILTER (WHERE f.operation_type = 'return'), 0)::numeric(14,2) AS total_returns,
  COALESCE(SUM(CASE WHEN f.direction = 'debit' THEN f.amount ELSE -f.amount END), 0)::numeric(14,2) AS current_debt
FROM public.vita_shops s
LEFT JOIN public.vita_shop_finances f ON f.shop_id = s.id
GROUP BY s.id;

GRANT SELECT ON public.vita_shop_finance_summary TO authenticated;

COMMIT;
