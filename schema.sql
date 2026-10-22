-- =====================================================================
-- Public Land Record: the database
--
-- A public, parcel-keyed record of what people want for the City of
-- Cleveland's land bank lots: open space, development, or yard expansion.
--
-- No gates, just evidence. Anyone can vote on any lot. Each vote records
-- how it was cast (how far the voter was from the lot, and the timing),
-- and display rules decide how much it counts. Only raw measurements are
-- stored. Every threshold (what "on site" means, what looks like a burst)
-- lives in a query, a function argument, or a view, so it can change
-- without touching the record.
--
-- Run this whole file in the Supabase SQL editor. It's safe to run again.
--
-- Tables (none readable by the public directly)
--   parcels       the city's land bank inventory with each lot's shape,
--                 synced hourly. Lots the city stops publishing are
--                 archived, never deleted, so their votes stay.
--   city_boundary the City of Cleveland (union of its wards). Votes cast
--                 from outside it are flagged, with no distance.
--   sync_settings where the lots and the boundary come from; last sync.
--   vote_events   every cast, change and clear, append-only. Never holds
--                 coordinates: only the rounded distance to the lot.
--   cards         printed voter cards: id and batch tag (provenance only).
--
-- What the public page can call
--   cast_vote(...)          the only way to write a vote
--   parcel_tallies(on_site_m) per-lot counts, on site and off site, and
--                           how each lot is drawn
--   my_votes(voter_id)      one voter's current votes (no timestamps)
--
-- For analysis (not public): current_votes, parcel_tally_rows(),
-- votes_flagged.
-- =====================================================================

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create extension if not exists postgis with schema extensions;
do $$ begin
  create extension if not exists http with schema extensions;
exception when others then raise notice 'http extension not available here; the city sync will not run: %', sqlerrm; end $$;
do $$ begin
  create extension if not exists pg_cron;
exception when others then raise notice 'pg_cron not available here; the city sync will not be scheduled: %', sqlerrm; end $$;


-- ------------------------------------------------------------------ tables

create table if not exists parcels (
  id          text primary key,              -- letters and digits of the parcel number, uppercase: 10131002
  pin         text not null,                 -- as the city publishes it
  address     text,
  category    text,
  geom        extensions.geography(MultiPolygon, 4326) not null,
  center      extensions.geography(Point, 4326) not null,   -- centroid, for implied travel between votes
  status      text not null default 'public' check (status in ('public', 'archived')),
  first_seen  timestamptz not null default now(),
  last_seen   timestamptz not null default now(),
  archived_at timestamptz
);
create index if not exists parcels_geom_idx on parcels using gist (geom);

create table if not exists city_boundary (
  id        boolean primary key default true check (id),
  geom      extensions.geometry(MultiPolygon, 4326) not null,
  source    text,
  loaded_at timestamptz not null default now()
);

create table if not exists sync_settings (
  id             boolean primary key default true check (id),
  layer_url      text not null,
  id_field       text not null,
  address_field  text,
  category_field text,
  boundary_url   text,
  last_edit      bigint,
  last_run       timestamptz,
  last_ok        timestamptz,
  last_result    jsonb
);
insert into sync_settings (layer_url, id_field, address_field, category_field, boundary_url) values (
  'https://services3.arcgis.com/dty2kHktVXHrqO8i/arcgis/rest/services/City_Landbank/FeatureServer/0',
  'parcelpin', 'par_addr_all', 'cityLandBankType',
  'https://services3.arcgis.com/dty2kHktVXHrqO8i/ArcGIS/rest/services/City_of_Cleveland_Wards_(2026)_view/FeatureServer/0')
on conflict (id) do nothing;

create table if not exists cards (
  id         uuid primary key default gen_random_uuid(),
  batch_tag  text check (length(batch_tag) between 1 and 120),   -- "Glenville block club, Nov". Provenance only.
  created_at timestamptz not null default now()
);

create table if not exists vote_events (
  id                 bigint generated always as identity primary key,
  voter_id           uuid not null,
  parcel_id          text not null references parcels(id),
  choice             text check (choice in ('open_space', 'development', 'yard_expansion')),   -- null: the vote was cleared
  created_at         timestamptz not null default clock_timestamp(),
  distance_m         int check (distance_m >= 0),        -- rounded by band; null: no location, or outside the city
  outside_city       boolean not null default false,     -- cast from outside the city (distance not kept)
  gps_accuracy_m     int check (gps_accuracy_m >= 0),
  fix_age_s          int check (fix_age_s >= 0),
  seconds_since_prev numeric(14, 3),                     -- since this voter's previous event (any lot)
  implied_speed_ms   numeric(12, 2),                     -- centroid-to-centroid distance from that lot / seconds_since_prev
  check (not (outside_city and distance_m is not null))
);
create index if not exists vote_events_voter_idx  on vote_events (voter_id, created_at desc, id desc);
create index if not exists vote_events_vp_idx     on vote_events (voter_id, parcel_id, created_at desc, id desc);
create index if not exists vote_events_parcel_idx on vote_events (parcel_id);

-- Append-only. To erase test data on purpose:  set local app.erase_votes = 'yes'; delete from vote_events where ...;
create or replace function vote_events_append_only() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' and current_setting('app.erase_votes', true) = 'yes' then return old; end if;
  raise exception 'vote_events is append-only';
end $$;
drop trigger if exists vote_events_append_only on vote_events;
create trigger vote_events_append_only before update or delete on vote_events
  for each row execute function vote_events_append_only();


-- ---------------------------------------------------------------- helpers

create or replace function norm_parcel(p text) returns text
language sql immutable set search_path = public as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Distance bands: under 200 m to the nearest 10 m; 200 m to 2 km to the nearest 100 m; beyond, the nearest 1 km.
create or replace function round_distance(d double precision) returns int
language sql immutable set search_path = public as $$
  select case
    when d is null then null
    when d < 200  then (round((d / 10)::numeric)   * 10)::int
    when d < 2000 then (round((d / 100)::numeric)  * 100)::int
    else               (round((d / 1000)::numeric) * 1000)::int
  end
$$;


-- --------------------------------------------------------- casting a vote
-- The only way to write a vote. Coordinates come in, a rounded distance goes out to the record, and the
-- coordinates are dropped. Nothing here logs or raises with the coordinates in it, and the page calls this
-- with POST so they never sit in a URL. Errors come back as {"error": "<code>"}.
-- choice null clears the voter's vote on that lot.
create or replace function cast_vote(
  voter_id   uuid,
  parcel_id  text,
  choice     text             default null,
  lat        double precision default null,
  lng        double precision default null,
  accuracy_m double precision default null,
  fix_age_s  double precision default null
) returns jsonb
language plpgsql volatile security definer
set search_path = public, extensions
set log_parameter_max_length_on_error = 0
as $$
#variable_conflict use_variable
declare
  pid text := norm_parcel(parcel_id);
  pg  extensions.geography;
  pc  extensions.geography;
  located boolean;
  pt  extensions.geometry;
  inside boolean;
  dist int;
  acc int;
  age int;
  cur text;
  prev_at timestamptz;
  prev_c extensions.geography;
  t_now timestamptz;
  secs numeric;
  speed numeric;
begin
  if voter_id is null then return jsonb_build_object('error', 'no_voter'); end if;
  if choice is not null and choice not in ('open_space', 'development', 'yard_expansion') then
    return jsonb_build_object('error', 'bad_choice');
  end if;
  select p.geom, p.center into pg, pc from parcels p where p.id = pid and p.status = 'public';
  if pg is null then return jsonb_build_object('error', 'parcel_not_found'); end if;

  -- One voter's events go in one at a time, so the time since their previous event is exact.
  perform pg_advisory_xact_lock(hashtextextended(voter_id::text, 0));

  select e.choice into cur from vote_events e
    where e.voter_id = voter_id and e.parcel_id = pid order by e.created_at desc, e.id desc limit 1;
  if choice is null and cur is null then
    return jsonb_build_object('ok', true, 'choice', null, 'unchanged', true);   -- nothing to clear
  end if;

  -- Where the voter was, reduced to a distance.
  located := lat is not null and lng is not null and lat between -90 and 90 and lng between -180 and 180;
  if located then
    pt := st_setsrid(st_makepoint(lng, lat), 4326);
    select st_covers(b.geom, pt) into inside from city_boundary b;
    if inside is false then
      dist := null;
    else
      dist := round_distance(st_distance(pg, pt::extensions.geography));
    end if;
    pt := null;
    acc := case when accuracy_m >= 0 then least(round(accuracy_m), 1000000)::int end;
    age := case when fix_age_s  >= 0 then least(round(fix_age_s), 100000000)::int end;
  end if;

  -- Timing against this voter's previous event, on any lot.
  select e.created_at, p.center into prev_at, prev_c
    from vote_events e join parcels p on p.id = e.parcel_id
    where e.voter_id = voter_id order by e.created_at desc, e.id desc limit 1;
  t_now := clock_timestamp();
  if prev_at is not null then
    secs := extract(epoch from (t_now - prev_at))::numeric;
    speed := case when secs > 0 then least(round((st_distance(prev_c, pc) / secs)::numeric, 2), 9999999999.99) end;
    secs := round(secs, 3);
  end if;

  insert into vote_events (voter_id, parcel_id, choice, created_at, distance_m, outside_city, gps_accuracy_m, fix_age_s,
                           seconds_since_prev, implied_speed_ms)
  values (voter_id, pid, choice, t_now, dist, coalesce(located and inside is false, false), acc, age, secs, speed);

  return jsonb_build_object('ok', true, 'choice', choice, 'distance_m', dist,
                            'outside_city', coalesce(located and inside is false, false));
end $$;


-- ------------------------------------------------------------- reading it

-- Each voter's latest event per lot, without clears: the votes that stand.
create or replace view current_votes with (security_invoker = true) as
select e.voter_id, e.parcel_id, e.choice, e.created_at, e.distance_m, e.outside_city, e.gps_accuracy_m, e.fix_age_s
from (
  select distinct on (v.voter_id, v.parcel_id) v.*
  from vote_events v
  order by v.voter_id, v.parcel_id, v.created_at desc, v.id desc
) e
where e.choice is not null;

-- Per-lot counts by choice, split at on_site_m (a vote with a distance at or under it is on site; no
-- distance or outside the city is off site), and how the lot is drawn:
--   solid    at least one on-site vote; colored by the leading on-site choice
--   hatched  only off-site votes; colored by the leading off-site choice
--   lead     the leading choice in the group that decides the color, or 'tie'
-- Lots with no votes aren't listed (they're drawn in the base style).
create or replace function parcel_tally_rows(on_site_m int default 100)
returns table (parcel_id text, on_open_space int, on_development int, on_yard_expansion int,
               off_open_space int, off_development int, off_yard_expansion int, display text, lead text)
language sql stable security definer set search_path = public as $$
  with c as (
    select v.parcel_id,
      count(*) filter (where v.distance_m <= on_site_m and v.choice = 'open_space')::int     as a1,
      count(*) filter (where v.distance_m <= on_site_m and v.choice = 'development')::int    as a2,
      count(*) filter (where v.distance_m <= on_site_m and v.choice = 'yard_expansion')::int as a3,
      count(*) filter (where not coalesce(v.distance_m <= on_site_m, false) and v.choice = 'open_space')::int     as b1,
      count(*) filter (where not coalesce(v.distance_m <= on_site_m, false) and v.choice = 'development')::int    as b2,
      count(*) filter (where not coalesce(v.distance_m <= on_site_m, false) and v.choice = 'yard_expansion')::int as b3
    from current_votes v
    group by v.parcel_id
  ), g as (
    select c.*, case when a1 + a2 + a3 > 0 then array[a1, a2, a3] else array[b1, b2, b3] end as k from c
  )
  select g.parcel_id, a1, a2, a3, b1, b2, b3,
    case when a1 + a2 + a3 > 0 then 'solid' else 'hatched' end,
    case
      when (select count(*) from unnest(k) x where x = (select max(y) from unnest(k) y)) > 1 then 'tie'
      when k[1] >= k[2] and k[1] >= k[3] then 'open_space'
      when k[2] >= k[3] then 'development'
      else 'yard_expansion'
    end
  from g
$$;

-- What the public map reads: one jsonb value (not rows, so there's no row cap), lots as
-- [parcel, on: open space, development, yard expansion, off: open space, development, yard expansion, display, lead].
create or replace function parcel_tallies(on_site_m int default 100) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'on_site_m', least(greatest(coalesce(on_site_m, 100), 0), 5000),
    'rows', coalesce((select jsonb_agg(jsonb_build_array(t.parcel_id, t.on_open_space, t.on_development, t.on_yard_expansion,
                        t.off_open_space, t.off_development, t.off_yard_expansion, t.display, t.lead))
                      from parcel_tally_rows(least(greatest(coalesce(on_site_m, 100), 0), 5000)) t), '[]'::jsonb))
$$;

-- One voter's current votes: [[parcel, choice, distance_m, outside_city], ...]. No timestamps, so a voter ID
-- never turns into a trail of where and when someone was.
create or replace function my_votes(voter_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(v.parcel_id, v.choice, v.distance_m, v.outside_city) order by v.parcel_id), '[]'::jsonb)
  from current_votes v where v.voter_id = my_votes.voter_id
$$;


-- ---------------------------------------------------------------- flags
-- Not stored anywhere: a view, rewritten whenever the rules change. Every number in `rules` is a
-- PLACEHOLDER to be tuned once real votes come in. One row per flagged event and reason.
create or replace view votes_flagged with (security_invoker = true) as
with rules as (
  select
    100            as on_site_m,       -- PLACEHOLDER: what counts as on site for these checks
    40.0::numeric  as max_speed_ms,    -- PLACEHOLDER: faster than this between two lots is implausible travel
    30             as burst_votes,     -- PLACEHOLDER: this many events ...
    interval '10 minutes' as burst_window,   -- PLACEHOLDER: ... within this long is a burst
    300            as max_fix_age_s,   -- PLACEHOLDER: an on-site vote from a location fix older than this
    150            as max_accuracy_m   -- PLACEHOLDER: an on-site vote from a fix less precise than this
), w as (
  select e.*, count(*) over (partition by e.voter_id order by e.created_at
                             range between (select burst_window from rules) preceding and current row) as in_window
  from vote_events e
)
select w.id, w.voter_id, w.parcel_id, w.choice, w.created_at, w.distance_m, w.seconds_since_prev, w.implied_speed_ms,
       w.gps_accuracy_m, w.fix_age_s, f.reason
from w cross join rules r
cross join lateral (values
  (case when w.distance_m <= r.on_site_m and w.implied_speed_ms > r.max_speed_ms then 'implied_travel' end),
  (case when w.in_window >= r.burst_votes then 'burst' end),
  (case when w.distance_m <= r.on_site_m and w.fix_age_s > r.max_fix_age_s then 'stale_fix' end),
  (case when w.distance_m <= r.on_site_m and w.gps_accuracy_m > r.max_accuracy_m then 'weak_fix' end)
) f(reason)
where f.reason is not null;


-- ------------------------------------------------------ syncing with the city

create or replace function city_get(p_url text) returns jsonb
language plpgsql set search_path = public, extensions as $$
declare st int; body text; j jsonb;
begin
  -- The http extension gives up connecting after 1 second by default; the city's service can take longer.
  begin
    execute $q$select extensions.http_set_curlopt('CURLOPT_CONNECTTIMEOUT', '20')$q$;
    execute $q$select extensions.http_set_curlopt('CURLOPT_TIMEOUT', '90')$q$;
  exception when others then null; end;
  execute 'select status, content from extensions.http_get($1)' into st, body using p_url;
  if st is distinct from 200 then raise exception 'The city service answered % for %', st, p_url; end if;
  j := body::jsonb;
  if j ? 'error' then raise exception 'The city service returned an error: %', j -> 'error'; end if;
  return j;
end $$;

-- A GeoJSON polygon from the city -> a valid MultiPolygon.
create or replace function to_multipolygon(g jsonb) returns extensions.geometry
language sql immutable set search_path = public, extensions as $$
  select st_multi(st_collectionextract(st_makevalid(st_setsrid(st_geomfromgeojson(g::text), 4326)), 3))
$$;

-- The city boundary: the union of the city's wards.
create or replace function sync_boundary() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare u text; g extensions.geometry; n int;
begin
  select boundary_url into u from sync_settings;
  if u is null then return jsonb_build_object('status', 'no_boundary_url'); end if;
  select st_multi(st_union(to_multipolygon(f -> 'geometry'))), count(*)
    into g, n
    from jsonb_array_elements(city_get(u || '/query?where=1%3D1&outFields=*&returnGeometry=true&outSR=4326&geometryPrecision=6&f=geojson') -> 'features') f
    where f -> 'geometry' is not null and f -> 'geometry' <> 'null'::jsonb;
  if g is null or n = 0 then return jsonb_build_object('status', 'failed', 'reason', 'no wards came back'); end if;
  insert into city_boundary (id, geom, source, loaded_at) values (true, g, u, now())
    on conflict (id) do update set geom = excluded.geom, source = excluded.source, loaded_at = now();
  return jsonb_build_object('status', 'loaded', 'wards', n);
end $$;

-- Brings parcels in line with the city's published inventory, shapes included. Checks the layer's last-edit
-- date first and stops there if nothing changed. Lots the city no longer publishes are archived with their
-- votes. Refuses (and changes nothing) if the city returns far fewer lots than expected; sync_city(true) overrides.
-- Also loads the city boundary if it's missing or more than 30 days old.
create or replace function sync_city(p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s sync_settings; meta jsonb; edit bigint; cnt int; size int; off int := 0; q text;
  feats jsonb := '[]'::jsonb; seen parcels[]; ids text[];
  got int; cur int; added int; relisted int; archived int; res jsonb; b jsonb;
begin
  select * into s from sync_settings;
  update sync_settings set last_run = now() where id;
  begin
    if not exists (select 1 from city_boundary where loaded_at > now() - interval '30 days') then
      begin b := sync_boundary(); exception when others then b := jsonb_build_object('status', 'failed', 'error', sqlerrm); end;
    end if;

    meta := city_get(s.layer_url || '?f=json');
    edit := coalesce(meta #>> '{editingInfo,dataLastEditDate}', meta #>> '{editingInfo,lastEditDate}')::bigint;
    if not p_force and edit is not null and edit = s.last_edit and s.last_ok is not null then
      res := jsonb_build_object('status', 'unchanged', 'edited', edit, 'boundary', b);
      update sync_settings set last_result = res where id;
      return res;
    end if;

    cnt  := (city_get(s.layer_url || '/query?where=1%3D1&returnCountOnly=true&f=json') ->> 'count')::int;
    size := least(coalesce((meta ->> 'maxRecordCount')::int, 1000), 2000);
    q    := s.layer_url || '/query?where=1%3D1&returnGeometry=true&outSR=4326&geometryPrecision=6&f=geojson'
         || '&outFields=' || concat_ws(',', s.id_field, s.address_field, s.category_field)
         || '&orderByFields=' || coalesce(meta ->> 'objectIdField', 'OBJECTID')
         || '&resultRecordCount=' || size || '&resultOffset=';
    while off < cnt loop
      feats := feats || coalesce(city_get(q || off) -> 'features', '[]'::jsonb);
      off := off + size;
    end loop;

    -- Every lot the city publishes now, as parcel rows (first one wins if a parcel number repeats).
    select array_agg(row(x.id, x.pin, x.address, x.category, x.g::extensions.geography, st_centroid(x.g)::extensions.geography,
                         'public', now(), now(), null)::parcels), array_agg(x.id)
      into seen, ids
      from (
        select distinct on (norm_parcel(f #>> array['properties', s.id_field]))
               norm_parcel(f #>> array['properties', s.id_field]) as id,
               trim(f #>> array['properties', s.id_field]) as pin,
               nullif(trim(f #>> array['properties', s.address_field]), '') as address,
               nullif(trim(f #>> array['properties', s.category_field]), '') as category,
               to_multipolygon(f -> 'geometry') as g
        from jsonb_array_elements(feats) f
        where norm_parcel(f #>> array['properties', s.id_field]) <> '' and jsonb_typeof(f -> 'geometry') = 'object'
      ) x
      where x.g is not null and not st_isempty(x.g);
    feats := null;

    got := coalesce(cardinality(seen), 0);
    select count(*) into cur from parcels where status = 'public';
    if got = 0 or (not p_force and (got < cnt * 0.98 or got < cur / 2)) then
      res := jsonb_build_object('status', 'refused', 'edited', edit, 'boundary', b, 'reason',
        format('The city returned %s lots of %s expected, with %s on the list now. Nothing changed. Run sync_city(true) to accept it anyway.', got, cnt, cur));
      update sync_settings set last_result = res where id;
      return res;
    end if;

    select count(*) filter (where p.id is null), count(*) filter (where p.status = 'archived')
      into added, relisted
      from unnest(seen) x left join parcels p on p.id = x.id;
    insert into parcels (id, pin, address, category, geom, center, status, last_seen, archived_at)
      select x.id, x.pin, x.address, x.category, x.geom, x.center, 'public', now(), null from unnest(seen) x
    on conflict (id) do update
      set pin = excluded.pin, address = excluded.address, category = excluded.category,
          geom = excluded.geom, center = excluded.center,
          status = 'public', last_seen = now(), archived_at = null;
    update parcels p set status = 'archived', archived_at = now()
      where p.status = 'public' and not (p.id = any (ids));
    get diagnostics archived = row_count;

    res := jsonb_build_object('status', 'synced', 'edited', edit, 'public', got, 'added', added,
                              'relisted', relisted, 'archived', archived, 'boundary', b);
    update sync_settings set last_edit = edit, last_ok = now(), last_result = res where id;
    return res;
  exception when others then
    res := jsonb_build_object('status', 'failed', 'error', sqlerrm, 'boundary', b);
    update sync_settings set last_result = res where id;
    return res;
  end;
end $$;


-- ------------------------------------------------------------------ access
-- The public (anon) can't read or write any table or view. It can call three functions.

alter table parcels       enable row level security;
alter table city_boundary enable row level security;
alter table sync_settings enable row level security;
alter table cards         enable row level security;
alter table vote_events   enable row level security;

revoke all on parcels, city_boundary, sync_settings, cards, vote_events from anon, authenticated;
revoke all on current_votes, votes_flagged from anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public'
             and p.proname in ('cast_vote', 'parcel_tallies', 'parcel_tally_rows', 'my_votes', 'norm_parcel', 'round_distance',
                               'city_get', 'to_multipolygon', 'sync_boundary', 'sync_city', 'vote_events_append_only') loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function cast_vote(uuid, text, text, double precision, double precision, double precision, double precision) to anon, authenticated;
grant execute on function parcel_tallies(int) to anon, authenticated;
grant execute on function my_votes(uuid)      to anon, authenticated;


-- ----------------------------------------- schedule the sync, run it once

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('city-sync', '17 * * * *', 'select public.sync_city()');
  end if;
end $$;

-- First load (16,000+ lot shapes): run   select sync_city();   by itself after this file.
-- How the last sync went:                select last_run, last_result from sync_settings;
