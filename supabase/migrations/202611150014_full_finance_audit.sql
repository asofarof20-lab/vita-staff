-- Preserve the full before/after finance record, not only the amount.
ALTER TABLE public.vita_finance_audit
  ADD COLUMN IF NOT EXISTS old_data jsonb,
  ADD COLUMN IF NOT EXISTS new_data jsonb;

CREATE OR REPLACE FUNCTION public.vita_log_finance_changes()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'pg_temp'
AS $function$
DECLARE
  v_user uuid;
  v_reason text;
  v_old jsonb;
  v_new jsonb;
  v_finance_id uuid;
  v_shop_id uuid;
  v_old_amount numeric;
  v_new_amount numeric;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    v_reason := NULLIF(trim(COALESCE(NEW.change_reason, '')), '');
    IF v_reason IS NULL THEN
      RAISE EXCEPTION 'Укажите причину изменения финансовой записи';
    END IF;
    v_user := COALESCE(auth.uid(), NEW.created_by, OLD.created_by);
    v_old := to_jsonb(OLD);
    v_new := to_jsonb(NEW);
    v_finance_id := NEW.id;
    v_shop_id := NEW.shop_id;
    v_old_amount := OLD.amount;
    v_new_amount := NEW.amount;

  ELSIF TG_OP = 'INSERT' THEN
    v_reason := NULLIF(trim(COALESCE(NEW.change_reason, NEW.note, '')), '');
    IF NEW.operation_type IN ('adjustment','return') AND v_reason IS NULL THEN
      RAISE EXCEPTION 'Укажите причину финансовой операции';
    END IF;
    v_user := COALESCE(auth.uid(), NEW.created_by);
    v_new := to_jsonb(NEW);
    v_finance_id := NEW.id;
    v_shop_id := NEW.shop_id;
    v_new_amount := NEW.amount;
    v_reason := COALESCE(v_reason, 'Создание финансовой записи');

  ELSIF TG_OP = 'DELETE' THEN
    v_reason := NULLIF(trim(COALESCE(OLD.change_reason, OLD.note, '')), '');
    v_user := COALESCE(auth.uid(), OLD.created_by);
    v_old := to_jsonb(OLD);
    v_finance_id := OLD.id;
    v_shop_id := OLD.shop_id;
    v_old_amount := OLD.amount;
    v_reason := COALESCE(v_reason, 'Удаление финансовой записи');
  END IF;

  IF v_user IS NULL THEN
    RAISE EXCEPTION 'Не удалось определить сотрудника, выполнившего финансовую операцию';
  END IF;

  INSERT INTO public.vita_finance_audit
    (finance_id, shop_id, changed_by, action, old_amount, new_amount,
     changed_at, reason, old_data, new_data)
  VALUES
    (v_finance_id, v_shop_id, v_user, TG_OP, v_old_amount, v_new_amount,
     now(), v_reason, v_old, v_new);

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.vita_log_finance_changes() FROM PUBLIC, anon, authenticated;

-- Direct authenticated accountant inserts must include an audit reason.
DROP POLICY IF EXISTS vita_shop_finances_accountant_insert ON public.vita_shop_finances;
CREATE POLICY vita_shop_finances_accountant_insert
  ON public.vita_shop_finances FOR INSERT TO authenticated
  WITH CHECK (
    public.vita_is_accountant()
    AND created_by = auth.uid()
    AND operation_type IN ('payment','return')
    AND direction = 'credit'
    AND amount > 0
    AND NULLIF(trim(COALESCE(change_reason,note,'')),'') IS NOT NULL
  );
