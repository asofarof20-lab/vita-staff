create or replace function public.vita_assign_catalog_order_delivery(p_order_id uuid,p_delivery_id uuid)
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
  select status,shop_id,delivery_id into v_status,v_shop_id,v_old_delivery
  from public.vita_orders where id=p_order_id and source='catalog' for update;
  if not found or v_status <> 'confirmed' then
    raise exception 'Назначить доставщика можно только подтверждённому и ещё не доставленному заказу';
  end if;
  if v_shop_id is null then raise exception 'У заказа не указан магазин'; end if;
  update public.vita_orders set delivery_id=p_delivery_id where id=p_order_id;
  insert into public.vita_order_audit(order_id,action,old_status,new_status,actor_id,details)
  values(p_order_id,'delivery_assigned',v_status,v_status,auth.uid(),
    jsonb_build_object('old_delivery_id',v_old_delivery,'new_delivery_id',p_delivery_id));
end;
$function$;
revoke all on function public.vita_assign_catalog_order_delivery(uuid,uuid) from public;
grant execute on function public.vita_assign_catalog_order_delivery(uuid,uuid) to authenticated;
