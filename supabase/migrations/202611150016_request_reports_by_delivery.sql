-- Admin and accountant request totals by delivery employee, scoped to a local date range.
CREATE OR REPLACE FUNCTION public.vita_sales_request_report(
  p_from date,
  p_to date
)
RETURNS TABLE(
  delivery_id uuid,
  delivery_name text,
  request_count bigint,
  completed_count bigint,
  pending_count bigint,
  cancelled_count bigint,
  total_amount numeric,
  paid_amount numeric,
  returned_amount numeric,
  debt_amount numeric,
  pending_amount numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
BEGIN
  IF NOT (public.vita_is_admin() OR public.vita_is_accountant()) THEN
    RAISE EXCEPTION 'Отчёт по всем заявкам доступен только администратору и бухгалтеру';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from THEN
    RAISE EXCEPTION 'Укажите корректный период отчёта';
  END IF;

  RETURN QUERY
  SELECT
    CASE WHEN GROUPING(r.delivery_id)=1 THEN NULL::uuid ELSE r.delivery_id END,
    CASE WHEN GROUPING(r.delivery_id)=1 THEN 'ИТОГО'
         ELSE COALESCE(s.full_name,s.username,'Доставщик') END,
    COUNT(*)::bigint,
    COUNT(*) FILTER (WHERE r.status='completed')::bigint,
    COUNT(*) FILTER (WHERE r.status='pending')::bigint,
    COUNT(*) FILTER (WHERE r.status='cancelled')::bigint,
    COALESCE(SUM(r.amount) FILTER (WHERE r.status IN ('completed','pending')),0)::numeric(14,2),
    COALESCE(SUM(r.paid_amount) FILTER (WHERE r.status='completed'),0)::numeric(14,2),
    COALESCE(SUM(r.returned_amount) FILTER (WHERE r.status='completed'),0)::numeric(14,2),
    COALESCE(SUM(GREATEST(r.amount-r.paid_amount-r.returned_amount,0)) FILTER (WHERE r.status='completed'),0)::numeric(14,2),
    COALESCE(SUM(r.amount) FILTER (WHERE r.status='pending'),0)::numeric(14,2)
  FROM public.vita_sales_requests r
  LEFT JOIN public.vita_staff s ON s.user_id=r.delivery_id
  WHERE r.created_at >= (p_from::timestamp AT TIME ZONE 'Asia/Dushanbe')
    AND r.created_at < ((p_to+1)::timestamp AT TIME ZONE 'Asia/Dushanbe')
  GROUP BY GROUPING SETS ((r.delivery_id,s.full_name,s.username),())
  ORDER BY GROUPING(r.delivery_id) DESC, 2;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_sales_request_report(date,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.vita_sales_request_report(date,date) TO authenticated;
