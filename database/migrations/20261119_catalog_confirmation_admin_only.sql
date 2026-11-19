-- VITANET test migration
-- Accountant may view/print catalog requests and assign a shop, but only admin may confirm.
-- Apply to the isolated VITANET test database first; do not apply to production before approval.

CREATE OR REPLACE FUNCTION public.vita_confirm_catalog_order(p_order_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_item record;
  v_old_status text;
  v_shop_id uuid;
begin
  if not public.vita_is_admin() then
    raise exception 'Подтвердить заказ может только администратор';
  end if;

  select status,shop_id into v_old_status,v_shop_id
  from public.vita_orders
  where id=p_order_id and source='catalog'
  for update;

  if not found or v_old_status <> 'new' then
    raise exception 'Заказ не найден или уже обработан';
  end if;
  if v_shop_id is null or not exists(select 1 from public.vita_shops where id=v_shop_id and active=true) then
    raise exception 'Сначала прикрепите действующий магазин к заказу';
  end if;
  if not exists(select 1 from public.vita_order_items where order_id=p_order_id) then
    raise exception 'В заказе нет товаров';
  end if;

  for v_item in
    select product_code,max(product_name) product_name,sum(quantity) qty
    from public.vita_order_items
    where order_id=p_order_id and product_code is not null
    group by product_code order by product_code
  loop
    insert into public.vita_stock(product_code,product_name,quantity)
    values(v_item.product_code,v_item.product_name,0)
    on conflict(product_code) do update
      set product_name=coalesce(excluded.product_name,public.vita_stock.product_name);
    perform 1 from public.vita_stock
    where product_code=v_item.product_code and quantity>=v_item.qty
    for update;
    if not found then
      raise exception 'Недостаточно товара на складе: %',v_item.product_code;
    end if;
  end loop;

  for v_item in
    select product_code,max(product_name) product_name,sum(quantity) qty
    from public.vita_order_items
    where order_id=p_order_id and product_code is not null
    group by product_code order by product_code
  loop
    update public.vita_stock
    set quantity=quantity-v_item.qty,product_name=coalesce(v_item.product_name,product_name),
        updated_at=now(),updated_by=auth.uid()
    where product_code=v_item.product_code;
    insert into public.vita_stock_movements(product_code,product_name,movement_type,quantity,order_id,note,created_by)
    values(v_item.product_code,v_item.product_name,'sale',v_item.qty,p_order_id,
      'Списание по подтверждённому заказу',auth.uid());
  end loop;

  update public.vita_orders
  set status='confirmed',confirmed_by=auth.uid(),confirmed_at=now()
  where id=p_order_id;
  insert into public.vita_order_audit(order_id,action,old_status,new_status,actor_id)
  values(p_order_id,'confirmed',v_old_status,'confirmed',auth.uid());
end;
$function$;
