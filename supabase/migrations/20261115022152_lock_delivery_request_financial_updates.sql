REVOKE UPDATE (status, delivery_result, paid_amount, returned_amount, delivery_note, completed_at)
ON TABLE public.vita_sales_requests
FROM PUBLIC, anon, authenticated;
