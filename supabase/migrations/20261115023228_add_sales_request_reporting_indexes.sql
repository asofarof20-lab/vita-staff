CREATE INDEX IF NOT EXISTS idx_vsr_created_delivery
ON public.vita_sales_requests (created_at, delivery_id);
CREATE INDEX IF NOT EXISTS idx_vsr_delivery_date_created
ON public.vita_sales_requests (delivery_date, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_vsr_sales_rep_delivery_date
ON public.vita_sales_requests (sales_rep_id, delivery_date, created_at DESC);
