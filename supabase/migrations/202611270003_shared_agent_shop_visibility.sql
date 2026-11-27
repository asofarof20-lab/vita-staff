-- Shared agent visibility for shops with debt or returned goods.
-- The shop's primary sales_rep_id is not changed; a second agent receives read-only visibility.
create table if not exists public.vita_shop_shared_agents (
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.vita_shops(id) on delete cascade,
  sales_rep_id uuid not null,
  source_request_id uuid not null references public.vita_sales_requests(id) on delete cascade,
  reason text not null check (reason in ('debt','return','debt_and_return')),
  created_at timestamptz not null default now(),
  unique (shop_id, sales_rep_id)
);
create index if not exists vita_shop_shared_agents_sales_rep_idx
  on public.vita_shop_shared_agents (sales_rep_id, shop_id);
alter table public.vita_shop_shared_agents enable row level security;
grant select on public.vita_shop_shared_agents to authenticated;
drop policy if exists vita_shop_shared_agents_read_self on public.vita_shop_shared_agents;
create policy vita_shop_shared_agents_read_self
  on public.vita_shop_shared_agents for select to authenticated
  using (sales_rep_id = (select auth.uid()));

drop policy if exists shops_read on public.vita_shops;
create policy shops_read on public.vita_shops for select to authenticated
using (
  vita_is_admin()
  or vita_staff_role() = 'accountant'
  or (vita_staff_role() = 'sales' and sales_rep_id = (select auth.uid()))
  or exists (
    select 1 from public.vita_shop_shared_agents a
    where a.shop_id = vita_shops.id and a.sales_rep_id = (select auth.uid())
  )
);

drop policy if exists "vita finance read" on public.vita_shop_finances;
create policy "vita finance read" on public.vita_shop_finances for select to authenticated
using (
  vita_is_admin()
  or vita_is_accountant()
  or vita_staff_role() = 'delivery'
  or exists (
    select 1 from public.vita_shops s
    where s.id = vita_shop_finances.shop_id
      and s.sales_rep_id = (select auth.uid())
  )
  or exists (
    select 1 from public.vita_shop_shared_agents a
    where a.shop_id = vita_shop_finances.shop_id
      and a.sales_rep_id = (select auth.uid())
  )
);

create or replace function public.vita_track_shared_shop_agent()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_debt numeric(14,2);
  v_reason text;
begin
  if new.status = 'completed'
     and old.status is distinct from 'completed'
     and new.sales_rep_id is not null
     and new.delivery_result is distinct from 'no_contact' then
    v_debt := greatest(0, coalesce(new.amount,0) - coalesce(new.paid_amount,0) - coalesce(new.returned_amount,0));
    if coalesce(new.returned_amount,0) > 0 or v_debt > 0 then
      v_reason := case
        when coalesce(new.returned_amount,0) > 0 and v_debt > 0 then 'debt_and_return'
        when coalesce(new.returned_amount,0) > 0 then 'return'
        else 'debt'
      end;
      insert into public.vita_shop_shared_agents(shop_id,sales_rep_id,source_request_id,reason)
      values(new.shop_id,new.sales_rep_id,new.id,v_reason)
      on conflict (shop_id,sales_rep_id) do nothing;
    end if;
  end if;
  return new;
end;
$$;
revoke all on function public.vita_track_shared_shop_agent() from public, anon, authenticated;
drop trigger if exists vita_track_shared_shop_agent_after_completion on public.vita_sales_requests;
create trigger vita_track_shared_shop_agent_after_completion
after update of status on public.vita_sales_requests
for each row execute function public.vita_track_shared_shop_agent();
