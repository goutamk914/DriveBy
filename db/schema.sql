create table if not exists vehicles (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users on delete cascade not null,
  make text, model text, year int,
  epa_city numeric, epa_hwy numeric, epa_combined numeric,
  mass_kg numeric default 1500
);
alter table vehicles add column if not exists epa_id int;
alter table vehicles add column if not exists fuel_type text;
alter table vehicles add column if not exists atv_type text;
alter table vehicles add column if not exists regen_factor numeric default 0;

create table if not exists drives (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users on delete cascade not null,
  vehicle_id uuid references vehicles on delete set null,
  started_at timestamptz not null,
  ended_at timestamptz,
  distance_m numeric,
  duration_s numeric,
  efficiency_score numeric,
  safety_score numeric,
  fuel_gal numeric,
  processed boolean default false
);
alter table drives add column if not exists hazard_opt_in boolean not null default true;
create index if not exists drives_user_started_idx on drives (user_id, started_at desc);

create table if not exists events (
  id uuid primary key default gen_random_uuid(),
  drive_id uuid references drives on delete cascade,
  t_offset_s numeric not null,
  kind text not null,
  severity numeric,
  lat numeric, lon numeric,
  detail jsonb,
  clip_path text
);
create index if not exists events_drive_idx on events (drive_id);
do $$ begin
  alter table events add constraint events_kind_check
    check (kind in ('hard_brake','hard_accel','harsh_corner','speeding','idle','lane_drift','tailgating'));
exception when duplicate_object then null; end $$;

create table if not exists fuel_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users on delete cascade not null,
  vehicle_id uuid references vehicles on delete set null,
  logged_at date not null,
  odometer_mi numeric not null,
  gallons numeric not null,
  price_total numeric
);
alter table fuel_logs add column if not exists filled_to_full boolean not null default true;

create table if not exists practice_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users on delete cascade not null,
  drive_id uuid,
  started_at timestamptz not null,
  duration_s numeric not null check (duration_s >= 0),
  night_s numeric not null default 0 check (night_s >= 0),
  supervisor text not null default '',
  notes text not null default '',
  manual boolean not null default false
);
create index if not exists practice_logs_user_idx on practice_logs (user_id, started_at desc);

create table if not exists hazard_cells (
  cell_key text primary key,
  lat numeric, lon numeric,
  event_count int not null,
  distinct_users int not null,
  dominant_kind text,
  updated_at timestamptz default now()
);

alter table vehicles enable row level security;
alter table drives enable row level security;
alter table events enable row level security;
alter table fuel_logs enable row level security;
alter table practice_logs enable row level security;
alter table hazard_cells enable row level security;

drop policy if exists "own vehicles" on vehicles;
create policy "own vehicles" on vehicles for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own drives" on drives;
create policy "own drives" on drives for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own events" on events;
create policy "own events" on events for all to authenticated
  using (exists (select 1 from drives d where d.id = events.drive_id and d.user_id = auth.uid()))
  with check (exists (select 1 from drives d where d.id = events.drive_id and d.user_id = auth.uid()));

drop policy if exists "own fuel logs" on fuel_logs;
create policy "own fuel logs" on fuel_logs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "own practice logs" on practice_logs;
create policy "own practice logs" on practice_logs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "hazard cells are public" on hazard_cells;
create policy "hazard cells are public" on hazard_cells for select to anon, authenticated using (true);
revoke insert, update, delete on hazard_cells from anon, authenticated;
grant select on hazard_cells to anon, authenticated;

create or replace function publish_hazard_cells(k_events int default 5, k_users int default 3)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  cell constant float8 := 0.0005;
  n int;
begin
  drop table if exists _agg;
  create temporary table _agg on commit drop as
  with contributions as (
    select e.lat::float8 as lat, e.lon::float8 as lon, e.kind, d.user_id
    from events e
    join drives d on d.id = e.drive_id
    where e.kind in ('hard_brake', 'harsh_corner')
      and d.hazard_opt_in
      and e.lat is not null and e.lon is not null
  ),
  keyed as (
    select round(lat / cell) * cell as clat,
           round(lon / cell) * cell as clon,
           kind, user_id
    from contributions
  )
  select round(clat::numeric, 4)::text || '_' || round(clon::numeric, 4)::text as cell_key,
         min(clat) as lat, min(clon) as lon,
         count(*)::int as event_count,
         count(distinct user_id)::int as distinct_users,
         mode() within group (order by kind) as dominant_kind
  from keyed
  group by 1
  having count(*) >= k_events and count(distinct user_id) >= k_users;

  delete from hazard_cells h where not exists (select 1 from _agg a where a.cell_key = h.cell_key);

  insert into hazard_cells (cell_key, lat, lon, event_count, distinct_users, dominant_kind, updated_at)
  select cell_key, lat, lon, event_count, distinct_users, dominant_kind, date_trunc('day', now())
  from _agg
  on conflict (cell_key) do update
    set event_count = excluded.event_count,
        distinct_users = excluded.distinct_users,
        dominant_kind = excluded.dominant_kind,
        lat = excluded.lat, lon = excluded.lon,
        updated_at = excluded.updated_at;

  select count(*) into n from hazard_cells;
  return n;
end;
$$;

revoke all on function publish_hazard_cells(int, int) from public, anon;
grant execute on function publish_hazard_cells(int, int) to authenticated;

create or replace function delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = auth.uid();
  perform publish_hazard_cells();
end;
$$;
revoke all on function delete_my_account() from public, anon;
grant execute on function delete_my_account() to authenticated;

insert into storage.buckets (id, name, public)
values ('clips', 'clips', false)
on conflict (id) do nothing;

drop policy if exists "own clips read" on storage.objects;
create policy "own clips read" on storage.objects for select to authenticated
  using (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own clips write" on storage.objects;
create policy "own clips write" on storage.objects for insert to authenticated
  with check (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own clips update" on storage.objects;
create policy "own clips update" on storage.objects for update to authenticated
  using (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "own clips delete" on storage.objects;
create policy "own clips delete" on storage.objects for delete to authenticated
  using (bucket_id = 'clips' and (storage.foldername(name))[1] = auth.uid()::text);
