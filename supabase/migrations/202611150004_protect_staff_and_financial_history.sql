-- Staff records are archived, never physically deleted.
DROP POLICY IF EXISTS staff_admin_all ON public.vita_staff;
DROP POLICY IF EXISTS staff_admin_insert ON public.vita_staff;
DROP POLICY IF EXISTS staff_admin_update ON public.vita_staff;

CREATE POLICY staff_admin_insert
  ON public.vita_staff FOR INSERT TO authenticated
  WITH CHECK (public.vita_is_admin());

CREATE POLICY staff_admin_update
  ON public.vita_staff FOR UPDATE TO authenticated
  USING (public.vita_is_admin())
  WITH CHECK (public.vita_is_admin());

REVOKE DELETE ON TABLE public.vita_staff FROM PUBLIC, anon, authenticated;
REVOKE DELETE ON TABLE public.vita_shops FROM PUBLIC, anon, authenticated;

-- Financial and audit ledgers are append-only from the client side.
REVOKE DELETE ON TABLE public.vita_shop_finances FROM PUBLIC, anon, authenticated;
REVOKE UPDATE, DELETE ON TABLE public.vita_finance_audit FROM PUBLIC, anon, authenticated;
REVOKE UPDATE, DELETE ON TABLE public.vita_operations_audit FROM PUBLIC, anon, authenticated;
REVOKE UPDATE, DELETE ON TABLE public.vita_cash_custody_movements FROM PUBLIC, anon, authenticated;
REVOKE UPDATE, DELETE ON TABLE public.vita_staff_cash_movements FROM PUBLIC, anon, authenticated;
REVOKE UPDATE, DELETE ON TABLE public.vita_finance_allocations FROM PUBLIC, anon, authenticated;
REVOKE UPDATE, DELETE ON TABLE public.vita_cash_collections FROM PUBLIC, anon, authenticated;

-- Do not allow deactivating/demoting the last active administrator.
CREATE OR REPLACE FUNCTION public.vita_guard_staff_archive()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cash numeric(12,2);
BEGIN
  IF OLD.active = true
     AND (NEW.active = false OR OLD.role IS DISTINCT FROM NEW.role) THEN

    IF OLD.role = 'admin'
       AND (NEW.active = false OR NEW.role IS DISTINCT FROM 'admin')
       AND NOT EXISTS (
         SELECT 1 FROM public.vita_staff s
         WHERE s.user_id <> OLD.user_id
           AND s.role = 'admin'
           AND s.active = true
       ) THEN
      RAISE EXCEPTION 'Нельзя отключить последнего активного администратора';
    END IF;

    SELECT cash_on_hand INTO v_cash
    FROM public.vita_cash_custody_balances
    WHERE staff_id = OLD.user_id;

    IF abs(COALESCE(v_cash, 0)) >= 0.01 THEN
      RAISE EXCEPTION 'Нельзя архивировать сотрудника: сначала закройте остаток денег на руках (%)', COALESCE(v_cash,0);
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.vita_sales_requests r
      WHERE r.status = 'pending'
        AND (r.sales_rep_id = OLD.user_id OR r.delivery_id = OLD.user_id)
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать сотрудника: у него есть незакрытые заявки';
    END IF;

    IF EXISTS (
      SELECT 1 FROM public.vita_cash_collections c
      WHERE c.received_by = OLD.user_id
        AND c.status = 'pending'
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать сотрудника: есть неподтверждённые приёмы денег';
    END IF;

    IF OLD.role = 'sales' AND EXISTS (
      SELECT 1 FROM public.vita_shops s
      WHERE s.sales_rep_id = OLD.user_id
        AND s.active = true
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать торгового представителя: сначала переназначьте его активные магазины';
    END IF;

    IF OLD.role = 'sales' AND EXISTS (
      SELECT 1
      FROM public.vita_shops s
      JOIN public.vita_shop_finance_summary fs ON fs.shop_id = s.id
      WHERE s.sales_rep_id = OLD.user_id
        AND fs.current_debt > 0.009
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать торгового представителя: у закреплённых магазинов остался долг';
    END IF;

    IF OLD.role = 'delivery' AND EXISTS (
      SELECT 1 FROM public.vita_shop_assignments a
      WHERE a.delivery_id = OLD.user_id
        AND a.active = true
    ) THEN
      RAISE EXCEPTION 'Нельзя архивировать доставщика: сначала переназначьте его маршрут';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_guard_staff_archive() FROM PUBLIC, anon, authenticated;
