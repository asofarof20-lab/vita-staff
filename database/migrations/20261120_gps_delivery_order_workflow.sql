-- VITANET workflow and GPS migration
-- Apply only after reviewing the VITANET deployment target.
-- GPS is recorded only during an explicitly started workday.

create unique index if not exists vita_staff_workdays_one_open_per_staff
on public.vita_staff_workdays(staff_id) where ended_at is null;

create index if not exists vita_staff_locations_latest_by_staff
on public.vita_staff_locations(staff_id, recorded_at desc);

alter table public.vita_shop_visits
  add column if not exists latitude double precision,
  add column if not exists longitude double precision,
  add column if not exists accuracy double precision;

create or replace function public.vita_start_workday()
returns uuid
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_id uuid;
begin
  if not exists (
    select 1 from public.vita_staff
    where user_id=auth.uid()
      and role in ('sales','delivery')
      and active=true
  ) then
    raise exception 'Начать рабочий день может только активный агент или доставщик';
  end if;

  select id into v_id
  from public.vita_staff_workdays
  where staff_id=auth.uid() and ended_at is null
  order by started_at desc
  limit 1;

  if v_id is not null then
    return v_id;
  end if;

  insert into public.vita_staff_workdays(staff_id)
  values(auth.uid())
  on conflict (staff_id) where ended_at is null do nothing
  returning id into v_id;

  if v_id is null then
    select id into v_id from public.vita_staff_workdays
    where staff_id=auth.uid() and ended_at is null
    order by started_at desc limit 1;
  end if;
  return v_id;
end;
$function$;

create or replace function public.vita_assign_catalog_order_delivery(
  p_order_id uuid,
  p_delivery_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_status text;
  v_shop_id uuid;
  v_old_delivery uuid;
begin
  if not public.vita_is_admin() then
    raise exception 'Назначить доставщика может только администратор';
  end if;

  if not exists (
    select 1 from public.vita_staff
    where user_id=p_delivery_id and role='delivery' and active=true
  ) then
    raise exception 'Выберите активного доставщика';
  end if;

  select status,shop_id,delivery_id
  into v_status,v_shop_id,v_old_delivery
  from public.vita_orders
  where id=p_order_id and source='catalog'
  for update;

  if not found or v_status not in ('confirmed','delivered') then
    raise exception 'Назначить доставщика можно только подтверждённому заказу';
  end if;
  if v_shop_id is null then
    raise exception 'У заказа не указан магазин';
  end if;

  update public.vita_orders set delivery_id=p_delivery_id where id=p_order_id;

  insert into public.vita_order_audit(order_id,action,old_status,new_status,actor_id,details)
  values(p_order_id,'delivery_assigned',v_status,v_status,auth.uid(),
    jsonb_build_object('old_delivery_id',v_old_delivery,'new_delivery_id',p_delivery_id));
end;
$function$;

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

  if not found or v_status <> 'confirmed' or v_delivery_id <> auth.uid() then
    raise exception 'Заказ не назначен вам или уже обработан';
  end if;

  update public.vita_orders
  set status='delivered',delivered_at=now()
  where id=p_order_id;

  insert into public.vita_order_audit(order_id,action,old_status,new_status,actor_id)
  values(p_order_id,'delivered',v_status,'delivered',auth.uid());
end;
$function$;

revoke all on function public.vita_start_workday() from public;
revoke all on function public.vita_end_workday() from public;
revoke all on function public.vita_assign_catalog_order_delivery(uuid,uuid) from public;
revoke all on function public.vita_mark_catalog_order_delivered(uuid) from public;
grant execute on function public.vita_start_workday() to authenticated;
grant execute on function public.vita_end_workday() to authenticated;
grant execute on function public.vita_assign_catalog_order_delivery(uuid,uuid) to authenticated;
grant execute on function public.vita_mark_catalog_order_delivered(uuid) to authenticated;
