-- VITANET GPS: isolated test migration. Apply ONLY to the dedicated test Supabase project.
create table if not exists public.vita_staff_location_status (
  user_id uuid primary key references public.vita_staff(user_id),
  latitude double precision,
  longitude double precision,
  accuracy_m integer,
  sharing_active boolean not null default false,
  updated_at timestamptz not null default now(),
  constraint vita_staff_location_status_lat_check check (latitude is null or latitude between -90 and 90),
  constraint vita_staff_location_status_lon_check check (longitude is null or longitude between -180 and 180)
);

create table if not exists public.vita_staff_location_history (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.vita_staff(user_id),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  accuracy_m integer,
  recorded_at timestamptz not null default now()
);

create index if not exists vita_staff_location_history_user_time_idx
  on public.vita_staff_location_history(user_id, recorded_at desc);
create index if not exists vita_staff_location_status_updated_idx
  on public.vita_staff_location_status(updated_at desc);

alter table public.vita_staff_location_status enable row level security;
alter table public.vita_staff_location_history enable row level security;

grant select, insert, update on public.vita_staff_location_status to authenticated;
grant select, insert on public.vita_staff_location_history to authenticated;
grant usage, select on sequence public.vita_staff_location_history_id_seq to authenticated;

drop policy if exists "staff read own gps or admin reads all" on public.vita_staff_location_status;
create policy "staff read own gps or admin reads all"
on public.vita_staff_location_status for select to authenticated
using (
  user_id = auth.uid()
  or exists (select 1 from public.vita_staff s where s.user_id = auth.uid() and s.role = 'admin' and s.active = true)
);

drop policy if exists "active staff write own gps status" on public.vita_staff_location_status;
create policy "active staff write own gps status"
on public.vita_staff_location_status for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from public.vita_staff s where s.user_id = auth.uid() and s.active = true and s.role in ('sales','delivery'))
);

drop policy if exists "active staff update own gps status" on public.vita_staff_location_status;
create policy "active staff update own gps status"
on public.vita_staff_location_status for update to authenticated
using (
  user_id = auth.uid()
  and exists (select 1 from public.vita_staff s where s.user_id = auth.uid() and s.active = true and s.role in ('sales','delivery'))
)
with check (
  user_id = auth.uid()
  and exists (select 1 from public.vita_staff s where s.user_id = auth.uid() and s.active = true and s.role in ('sales','delivery'))
);

drop policy if exists "staff insert own gps history" on public.vita_staff_location_history;
create policy "staff insert own gps history"
on public.vita_staff_location_history for insert to authenticated
with check (
  user_id = auth.uid()
  and exists (select 1 from public.vita_staff s where s.user_id = auth.uid() and s.active = true and s.role in ('sales','delivery'))
);

drop policy if exists "staff read own gps history or admin reads all" on public.vita_staff_location_history;
create policy "staff read own gps history or admin reads all"
on public.vita_staff_location_history for select to authenticated
using (
  user_id = auth.uid()
  or exists (select 1 from public.vita_staff s where s.user_id = auth.uid() and s.role = 'admin' and s.active = true)
);
