create or replace function public.vita_confirm_catalog_order(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_item record;
  v_old_status text;
  v_shop_id uuid;
  v_total numeric;
  v_payment_type text;
  v_customer_phone text;
  v_match_count integer := 0;
begin
  if not (public.vita_is_admin() or public.vita_staff_role() = 'accountant') then
    raise exception 'Подтвердить заказ может только администратор или бухгалтер';
  end if;

  select status,shop_id,total,payment_type,customer_phone
    into v_old_status,v_shop_id,v_total,v_payment_type,v_customer_phone
    from public.vita_orders
   where id=p_order_id and source='catalog'
   for update;

  if not found or v_old_status <> 'new' then
    raise exception 'Заказ не найден или уже обработан';
  end if;

  if v_shop_id is null then
    select count(*), (array_agg(s.id))[1]
      into v_match_count,v_shop_id
      from public.vita_shops s
     where s.active=true
       and right(regexp_replace(coalesce(s.phone,''),'[^0-9]','','g'),9)
           = right(regexp_replace(coalesce(v_customer_phone,''),'[^0-9]','','g'),9)
       and length(regexp_replace(coalesce(v_customer_phone,''),'[^0-9]','','g')) >= 9;
    if v_match_count=1 then
      update public.vita_orders set shop_id=v_shop_id where id=p_order_id;
    elsif v_match_count>1 then
      raise exception 'Найдено несколько магазинов с таким телефоном. Уточните номер или привяжите магазин вручную';
    end if;
  end if;

  if v_shop_id is null or not exists(select 1 from public.vita_shops where id=v_shop_id and active=true) then
    raise exception 'Не найден единственный действующий магазин по номеру телефона. Привяжите магазин к заказу вручную';
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
       set quantity=quantity-v_item.qty,
           product_name=coalesce(v_item.product_name,product_name),
           updated_at=now(),updated_by=auth.uid()
     where product_code=v_item.product_code;
    insert into public.vita_stock_movements(
      product_code,product_name,movement_type,quantity,order_id,note,created_by
    ) values (
      v_item.product_code,v_item.product_name,'sale',v_item.qty,p_order_id,
      'Списание по подтверждённому заказу',auth.uid()
    );
  end loop;

  insert into public.vita_shop_finances(
    shop_id,operation_type,amount,direction,note,created_by,order_id
  ) values (
    v_shop_id,'sale',v_total,'debit','Заказ из каталога № '||p_order_id::text,auth.uid(),p_order_id
  );

  if v_payment_type='cash' then
    insert into public.vita_shop_finances(
      shop_id,operation_type,amount,direction,payment_method,note,created_by,order_id
    ) values (
      v_shop_id,'payment',v_total,'credit','cash','Оплата наличными по заказу из каталога',
      auth.uid(),p_order_id
    );
  end if;

  update public.vita_orders
     set status='confirmed',confirmed_by=auth.uid(),confirmed_at=now()
   where id=p_order_id;
  insert into public.vita_order_audit(order_id,action,old_status,new_status,actor_id,details)
  values(
    p_order_id,'confirmed',v_old_status,'confirmed',auth.uid(),
    jsonb_build_object('payment_type',v_payment_type,'total',v_total,'shop_id',v_shop_id,'phone_auto_matched',v_match_count=1)
  );
end;
$function$;
