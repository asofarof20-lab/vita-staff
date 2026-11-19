-- Tighten assigned-delivery ownership check against NULL delivery_id.
create or replace function public.vita_mark_catalog_order_delivered(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_status text;
  v_delivery_id uuid;
begin
  if not exists (
    select 1 from public.vita_staff
    where user_id=auth.uid() and role='delivery' and active=true
  ) then
    raise exception 'Отметить доставку может только активный доставщик';
  end if;

  select status,delivery_id into v_status,v_delivery_id
  from public.vita_orders
  where id=p_order_id and source='catalog'
  for update;

  if not found or v_status <> 'confirmed' or v_delivery_id is distinct from auth.uid() then
    raise exception 'Заказ не назначен вам или уже обработан';
  end if;

  update public.vita_orders
  set status='delivered',delivered_at=now()
  where id=p_order_id;

  insert into public.vita_order_audit(order_id,action,old_status,new_status,actor_id)
  values(p_order_id,'delivered',v_status,'delivered',auth.uid());
end;
$function$;
revoke all on function public.vita_mark_catalog_order_delivered(uuid) from public;
grant execute on function public.vita_mark_catalog_order_delivered(uuid) to authenticated;
