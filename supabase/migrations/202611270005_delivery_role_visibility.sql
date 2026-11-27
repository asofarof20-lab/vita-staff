-- Restore delivery staff access to their assigned delivery requests and shops only.
drop policy if exists shops_read on public.vita_shops;
create policy shops_read on public.vita_shops
for select to authenticated
using (
  vita_is_admin()
  or vita_is_accountant()
  or (vita_staff_role() = 'sales' and sales_rep_id = (select auth.uid()))
  or exists (
    select 1 from public.vita_shop_shared_agents a
    where a.shop_id = vita_shops.id and a.sales_rep_id = (select auth.uid())
  )
  or (
    vita_staff_role() = 'delivery'
    and exists (
      select 1 from public.vita_sales_requests r
      where r.shop_id = vita_shops.id and r.delivery_id = (select auth.uid())
    )
  )
);

-- This is a trigger function, not a public RPC endpoint.
revoke all on function public.vita_recalculate_agent_shop_visibility() from public, anon, authenticated;
