-- =====================================================================
-- Public Land Voting Tool (proximity version): the database
--
-- A public, parcel-keyed record of what people want for the City of
-- Cleveland's land bank lots: open space, development, or yard expansion.
--
-- No gates, just evidence. Anyone can vote on any lot. Each vote records
-- how it was cast (how far the voter was from the lot, whether they were
-- in the lot's neighborhood and ward, and the timing), and display rules
-- decide how much it counts. Only measurements are stored. Every threshold
-- (what "at the lot" means) lives in a function or view, so it can change
-- without touching the record. Timing has no thresholds at all: each vote
-- keeps the seconds since the voter's previous vote, and the public data
-- compares it with every other vote in the record.
--
-- Version 3 adds what's lost if it isn't captured at the cast: how fast
-- the voter was moving, what was on their screen (everyone's votes, the
-- Show votes cast filter, the city's record for the lot), phone or
-- computer, whether they came from a card link, the page version, why
-- there was no location, and their group code. Group codes are for
-- organizing, not evidence: they never change counts, colors or which
-- votes come first. Everything else (vote order, pace, patterns across a
-- voter's votes) is computed later from the record.
--
-- Distances are in feet.
--
-- Run this whole file in the Supabase SQL editor. It's safe to run again,
-- and it upgrades a database built from any earlier version.
--
-- Tables (none readable by the public directly)
--   parcels       the city's land bank inventory with each lot's shape and
--                 its neighborhood, ward and planning region, synced
--                 hourly. Lots the city stops publishing are archived,
--                 never deleted, so their votes stay.
--   places        the city's neighborhoods (SPAs), wards and design review
--                 (planning) regions, from the city's own layers.
--   city_boundary the City of Cleveland (union of its wards).
--   sync_settings / place_sources   where all of that comes from.
--   vote_events   every cast, change and clear, append-only. Never holds
--                 coordinates: only the rounded distance to the lot and
--                 whether the voter was inside the lot's neighborhood and
--                 ward.
--   cards         printed voter cards: id and batch tag (provenance only).
--   groups        group codes (MAPLE-RIVER-42) and when they were made.
--                 No names, owners or keys.
--
-- What the public page can call
--   cast_vote(...)        the only way to write a vote
--   lot_tallies(farthest, group_code)   per-lot counts by where votes were
--                         cast, timing, and how each lot is drawn
--   my_votes(voter_id)    one voter's current votes (no timestamps)
--   lot_info(parcel_id)   a lot's neighborhood, ward and planning region
--   export_lots(), export_votes()   the public data, for CSV download
--   create_group(), group_exists(code)   make a group code; check one
--   export_group_lots(code), export_group_votes(code)   one group's data
--
-- For analysis (not public): current_votes, lot_tally_rows(), votes_flagged.
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
alter table parcels add column if not exists neighborhood text;   -- names in places (kind 'neighborhood')
alter table parcels add column if not exists ward text;
alter table parcels add column if not exists region text;
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

-- The city's boundary layers. name_field names each polygon; polygons sharing a name are merged.
create table if not exists place_sources (
  kind       text primary key check (kind in ('neighborhood', 'ward', 'region')),
  url        text not null,
  name_field text not null,
  title_case boolean not null default false     -- "EUCLID CORRIDOR/BUCKEYE" -> "Euclid Corridor/Buckeye"
);
insert into place_sources (kind, url, name_field, title_case) values
  ('neighborhood', 'https://services3.arcgis.com/dty2kHktVXHrqO8i/ArcGIS/rest/services/Cleveland_SPA_Neighborhoods_Salesforce/FeatureServer/0', 'SPANM', false),
  ('ward',         'https://services3.arcgis.com/dty2kHktVXHrqO8i/ArcGIS/rest/services/City_of_Cleveland_Wards_(2026)_view/FeatureServer/0', 'NAME', false),
  ('region',       'https://www.clevelandgis.org/arcgis/rest/services/AGOServices/PlanningWAB/MapServer/98', 'REGION', true)
on conflict (kind) do nothing;

create table if not exists places (
  kind      text not null check (kind in ('neighborhood', 'ward', 'region')),
  name      text not null,
  geom      extensions.geometry(MultiPolygon, 4326) not null,
  attrs     jsonb,                                -- the city's fields for each source polygon (e.g. a region's planner)
  loaded_at timestamptz not null default now(),
  primary key (kind, name)
);
create index if not exists places_geom_idx on places using gist (geom);

create table if not exists cards (
  id         uuid primary key default gen_random_uuid(),
  batch_tag  text check (length(batch_tag) between 1 and 120),   -- "Glenville block club, Nov". Provenance only.
  created_at timestamptz not null default now()
);

-- Group codes: two words and a number, MAPLE-RIVER-42. Made by create_group(); never deleted.
create table if not exists groups (
  code       text primary key check (code ~ '^[A-Z]+-[A-Z]+-[0-9]{2}$'),
  created_at timestamptz not null default now()
);

create table if not exists vote_events (
  id                 bigint generated always as identity primary key,
  voter_id           uuid not null,
  parcel_id          text not null references parcels(id),
  choice             text check (choice in ('open_space', 'development', 'yard_expansion')),   -- null: the vote was cleared
  created_at         timestamptz not null default clock_timestamp(),
  distance_ft        int check (distance_ft >= 0),   -- rounded by band; null: no location, or outside the city
  outside_city       boolean not null default false, -- cast from outside the city (distance not kept)
  gps_accuracy_m     int check (gps_accuracy_m >= 0),   -- as the phone reports it (meters)
  fix_age_s          int check (fix_age_s >= 0),
  seconds_since_prev numeric(14, 3),                 -- since this voter's previous event (any lot)
  implied_speed_ms   numeric(12, 2),                 -- centroid-to-centroid distance from that lot / seconds_since_prev
  check (not (outside_city and distance_ft is not null))
);

-- Upgrading from the Oct 21 version: distances moved from meters to feet, and votes record whether
-- they were cast inside the lot's neighborhood and ward.
do $$
declare n bigint;
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'vote_events' and column_name = 'distance_m') then
    execute 'drop view if exists current_votes cascade';
    execute 'drop view if exists votes_flagged cascade';
    alter table vote_events rename column distance_m to distance_ft;
    select count(*) into n from vote_events where distance_ft is not null;
    if n > 0 then   -- convert stored meters to feet (the append-only trigger is paused for this one change)
      alter table vote_events disable trigger vote_events_append_only;
      update vote_events set distance_ft = round(distance_ft * 3.28084)::int where distance_ft is not null;
      alter table vote_events enable trigger vote_events_append_only;
    end if;
  end if;
end $$;
alter table vote_events add column if not exists in_neighborhood boolean;   -- inside the lot's neighborhood; null: unknown
alter table vote_events add column if not exists in_ward boolean;           -- inside the lot's ward; null: unknown

-- Version 3: what's captured at the cast. All nullable; votes from before stay blank.
alter table vote_events add column if not exists speed_ms real
  check (speed_ms >= 0 and speed_ms <= 100000);                                -- how fast the voter was moving (m/s); null: no fix
alter table vote_events add column if not exists speed_source text
  check (speed_source in ('gps', 'fixes'));                                    -- the phone's own speed, or worked out from its last two fixes
alter table vote_events add column if not exists saw_everyone boolean;         -- everyone's votes were showing (not just the voter's own)
alter table vote_events add column if not exists filter_at_cast text
  check (filter_at_cast in ('lot', 'block', 'neighborhood', 'ward', 'city', 'all'));   -- the Show votes cast filter
alter table vote_events add column if not exists group_filter_at_cast text references groups(code);   -- the group in that filter
alter table vote_events add column if not exists opened_record boolean;        -- the city's record was opened on this lot's card first
alter table vote_events add column if not exists touch_device boolean;         -- a touch screen (pointer: coarse): phone or tablet
alter table vote_events add column if not exists arrived_via text
  check (arrived_via in ('card_link', 'direct'));                              -- this page load came from a ?card= link
alter table vote_events add column if not exists page_version text
  check (length(page_version) <= 32);                                          -- the page's PAGE_VERSION
alter table vote_events add column if not exists group_code text references groups(code);   -- the device's group
alter table vote_events add column if not exists location_status text
  check (location_status in ('ok', 'declined', 'denied', 'unavailable', 'timeout', 'unsupported', 'waiting'));

create index if not exists vote_events_voter_idx  on vote_events (voter_id, created_at desc, id desc);
create index if not exists vote_events_vp_idx     on vote_events (voter_id, parcel_id, created_at desc, id desc);
create index if not exists vote_events_parcel_idx on vote_events (parcel_id);

-- Append-only. To erase test data on purpose:  begin; set local app.erase_votes = 'yes'; delete from vote_events where ...; commit;
create or replace function vote_events_append_only() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'DELETE' and current_setting('app.erase_votes', true) = 'yes' then return old; end if;
  raise exception 'vote_events is append-only';
end $$;
drop trigger if exists vote_events_append_only on vote_events;
create trigger vote_events_append_only before update or delete on vote_events
  for each row execute function vote_events_append_only();

-- Replaced by the functions below.
drop function if exists parcel_tallies(int);
drop function if exists parcel_tally_rows(int);
drop function if exists round_distance(double precision);


-- ---------------------------------------------------------------- helpers

create or replace function norm_parcel(p text) returns text
language sql immutable set search_path = public as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Distance bands, in feet: under 1,000 ft to the nearest 10 ft; 1,000 ft to 2 miles to the nearest 100 ft;
-- beyond that, to the nearest half mile.
create or replace function round_distance_ft(ft double precision) returns int
language sql immutable set search_path = public as $$
  select case
    when ft is null then null
    when ft < 1000  then (round((ft / 10)::numeric)   * 10)::int
    when ft < 10560 then (round((ft / 100)::numeric)  * 100)::int
    else                 (round((ft / 2640)::numeric) * 2640)::int
  end
$$;

-- Where a vote was cast from, nearest first. The rule, not stored anywhere; change it here.
--   lot           within 200 ft of the lot          (on site)
--   block         within 500 ft
--   neighborhood  inside the lot's neighborhood (city SPA)
--   ward          inside the lot's ward
--   city          elsewhere in Cleveland
--   outside       outside the city
--   none          no location
create or replace function vote_tier(distance_ft int, outside_city boolean, in_neighborhood boolean, in_ward boolean) returns text
language sql immutable set search_path = public as $$
  select case
    when outside_city            then 'outside'
    when distance_ft is null     then 'none'
    when distance_ft <= 200      then 'lot'
    when distance_ft <= 500      then 'block'
    when in_neighborhood         then 'neighborhood'
    when in_ward                 then 'ward'
    else 'city'
  end
$$;
create or replace function tier_rank(tier text) returns int
language sql immutable set search_path = public as $$
  select array_position(array['lot', 'block', 'neighborhood', 'ward', 'city', 'outside', 'none'], tier)
$$;

-- A group code as typed -> its stored form: trimmed, uppercased, spaces turned into hyphens.
-- " maple river 42 " -> "MAPLE-RIVER-42". The page does the same (normGroup); this one decides.
-- Empty -> null. Anything too long to be a code -> '' (matches no group).
create or replace function norm_group(c text) returns text
language sql immutable set search_path = public as $$
  select case
    when c is null or btrim(c) = '' then null
    when length(c) > 80 then ''
    else regexp_replace(upper(btrim(c)), '\s+', '-', 'g')
  end
$$;
-- The group a code names, or null if there isn't one.
create or replace function find_group(c text) returns text
language sql stable security definer set search_path = public as $$
  select g.code from groups g where g.code = norm_group(c)
$$;

-- Upgrading from the first Oct 22 version: timing labels (rapid/steady/unhurried, from fixed cutoffs) are
-- replaced by the raw seconds and a comparison with every other vote.
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'current_votes' and column_name = 'pace') then
    execute 'drop view current_votes';
  end if;
end $$;
drop function if exists vote_pace(numeric);
drop function if exists lot_tally_rows(text);
drop function if exists lot_tallies(text);


-- --------------------------------------------------------- casting a vote
-- The only way to write a vote. Coordinates come in; a rounded distance and two yes/no answers (inside the
-- lot's neighborhood? its ward?) go to the record; the coordinates are dropped. Nothing here logs or raises
-- with the coordinates in it, and the page calls this with POST so they never sit in a URL.
-- Errors come back as {"error": "<code>"} and write nothing. choice null clears the voter's vote on that lot.
--
-- Version 3 fields (all optional; the version 2 page sends none of them):
--   speed_ms, speed_source   the phone's speed ('gps') or one worked out from its last two fixes ('fixes').
--                            Kept only with a location; capped to fit the column.
--   saw_everyone             everyone's votes were showing
--   filter_at_cast           the Show votes cast filter; an unknown value is stored as null
--   group_filter_at_cast     the group in that filter; kept only if it's a real group
--   opened_record            the lot's city record was opened before this vote
--   touch_device             a touch screen
--   arrived_via              'card_link' or 'direct'; anything else is stored as null
--   page_version             the page's version; letters, digits, '.', '-' and '_' only, 32 at most
--   group_code               the device's group. An unknown code -> {"error": "bad_group"}
--   location_status          ok | declined | denied | unavailable | timeout | unsupported | waiting.
--                            Anything else -> {"error": "bad_location_status"}. With coordinates it's
--                            always 'ok'. 'ok' without coordinates is stored as null.
-- A vote's group is the one on its latest cast (like its tier): re-casting without a code takes it out.
drop function if exists cast_vote(uuid, text, text, double precision, double precision, double precision, double precision);
create or replace function cast_vote(
  voter_id   uuid,
  parcel_id  text,
  choice     text             default null,
  lat        double precision default null,
  lng        double precision default null,
  accuracy_m double precision default null,
  fix_age_s  double precision default null,
  speed_ms             double precision default null,
  speed_source         text    default null,
  saw_everyone         boolean default null,
  filter_at_cast       text    default null,
  group_filter_at_cast text    default null,
  opened_record        boolean default null,
  touch_device         boolean default null,
  arrived_via          text    default null,
  page_version         text    default null,
  group_code           text    default null,
  location_status      text    default null
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
  nb  text;
  wd  text;
  located boolean;
  pt  extensions.geometry;
  inside boolean;
  in_n boolean;
  in_w boolean;
  dist int;
  outside boolean;
  acc int;
  age int;
  cur text;
  prev_at timestamptz;
  prev_c extensions.geography;
  t_now timestamptz;
  secs numeric;
  speed numeric;
  grp text;
  gflt text;
  st text;
  spd real;
  spd_src text;
  flt text;
  via text;
  ver text;
begin
  if voter_id is null then return jsonb_build_object('error', 'no_voter'); end if;
  if choice is not null and choice not in ('open_space', 'development', 'yard_expansion') then
    return jsonb_build_object('error', 'bad_choice');
  end if;
  located := lat is not null and lng is not null and lat between -90 and 90 and lng between -180 and 180;

  -- Checked before anything is written.
  if norm_group(group_code) is not null then
    grp := find_group(group_code);
    if grp is null then return jsonb_build_object('error', 'bad_group'); end if;
  end if;
  st := case when located then 'ok' else location_status end;
  if st is not null and st not in ('ok', 'declined', 'denied', 'unavailable', 'timeout', 'unsupported', 'waiting') then
    return jsonb_build_object('error', 'bad_location_status');
  end if;
  if st = 'ok' and not located then st := null; end if;

  select p.geom, p.center, p.neighborhood, p.ward into pg, pc, nb, wd from parcels p where p.id = pid and p.status = 'public';
  if pg is null then return jsonb_build_object('error', 'parcel_not_found'); end if;

  -- The rest of what was on the screen, reduced to known values.
  gflt := find_group(group_filter_at_cast);
  flt := case when filter_at_cast in ('lot', 'block', 'neighborhood', 'ward', 'city', 'all') then filter_at_cast end;
  via := case when arrived_via in ('card_link', 'direct') then arrived_via end;
  ver := nullif(left(regexp_replace(coalesce(page_version, ''), '[^A-Za-z0-9._-]', '', 'g'), 32), '');
  if located and speed_ms >= 0 and speed_ms < 'Infinity'::double precision then   -- NaN and negatives are dropped
    spd := least(speed_ms, 100000)::real;
    spd_src := case when speed_source in ('gps', 'fixes') then speed_source end;
  end if;

  -- One voter's events go in one at a time, so the time since their previous event is exact.
  perform pg_advisory_xact_lock(hashtextextended(voter_id::text, 0));

  select e.choice into cur from vote_events e
    where e.voter_id = voter_id and e.parcel_id = pid order by e.created_at desc, e.id desc limit 1;
  if choice is null and cur is null then
    return jsonb_build_object('ok', true, 'choice', null, 'unchanged', true);   -- nothing to clear
  end if;

  -- Where the voter was, reduced to a distance and two yes/no answers.
  outside := false;
  if located then
    pt := st_setsrid(st_makepoint(lng, lat), 4326);
    select st_covers(b.geom, pt) into inside from city_boundary b;
    if inside is false then
      outside := true; in_n := false; in_w := false;
    else
      dist := round_distance_ft(st_distance(pg, pt::extensions.geography) * 3.28084);
      select st_covers(x.geom, pt) into in_n from places x where x.kind = 'neighborhood' and x.name = nb;
      select st_covers(x.geom, pt) into in_w from places x where x.kind = 'ward' and x.name = wd;
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

  insert into vote_events (voter_id, parcel_id, choice, created_at, distance_ft, outside_city, in_neighborhood, in_ward,
                           gps_accuracy_m, fix_age_s, seconds_since_prev, implied_speed_ms,
                           speed_ms, speed_source, saw_everyone, filter_at_cast, group_filter_at_cast, opened_record,
                           touch_device, arrived_via, page_version, group_code, location_status)
  values (voter_id, pid, choice, t_now, dist, outside, in_n, in_w, acc, age, secs, speed,
          spd, spd_src, saw_everyone, flt, gflt, opened_record, touch_device, via, ver, grp, st);

  return jsonb_build_object('ok', true, 'choice', choice, 'distance_ft', dist, 'outside_city', outside,
                            'tier', vote_tier(dist, outside, in_n, in_w), 'group_code', grp, 'location_status', st);
end $$;


-- ------------------------------------------------------------- reading it

-- Each voter's latest event per lot, without clears: the votes that stand. A vote's distance, tier and group
-- are those of its latest cast.
create or replace view current_votes with (security_invoker = true) as
select e.voter_id, e.parcel_id, e.choice, e.created_at, e.distance_ft, e.outside_city, e.gps_accuracy_m, e.fix_age_s,
       e.in_neighborhood, e.in_ward, e.seconds_since_prev,
       vote_tier(e.distance_ft, e.outside_city, e.in_neighborhood, e.in_ward) as tier,
       e.group_code, e.speed_ms, e.speed_source, e.saw_everyone, e.filter_at_cast, e.group_filter_at_cast,
       e.opened_record, e.touch_device, e.arrived_via, e.page_version, e.location_status
from (
  select distinct on (v.voter_id, v.parcel_id) v.*
  from vote_events v
  order by v.voter_id, v.parcel_id, v.created_at desc, v.id desc
) e
where e.choice is not null;

-- Timing compared with the record: the share (0-100) of all current votes that came sooner after the voter's
-- previous vote than `seconds`. 70 reads "took longer than 70% of votes". Votes without a previous vote (a
-- voter's first) aren't in the comparison. No cutoffs: the comparison moves as votes come in. With a group
-- filter, the comparison is still with every vote in the record.

-- Per lot: counts by where the votes were cast (7 tiers, nearest first) and choice, timing, and how the
-- lot is drawn. The nearest tier with votes decides the color; a tie there is grey.
--   counts          21 numbers: for each tier (lot, block, neighborhood, ward, city, outside, none),
--                   open space, development, yard expansion
--   timed           how many of the lot's votes have a time since the voter's previous vote
--   median_seconds  the median of those times
--   median_pct      that median compared with every vote in the record (see above)
--   tier            the nearest tier with votes, among those shown
--   lead            its leading choice, or 'tie'
--   display         'solid' (decided by votes at the lot), 'hatched' (by votes from farther away), or null
--                   (this lot's votes are all farther than `farthest`)
-- farthest: show only votes cast this close or closer ('lot', 'block', 'neighborhood', 'ward', 'city',
-- or 'all'). group_code: only that group's votes (null: everyone's). Both change what's shown, never the
-- record. Nearest-tier precedence and grey ties apply within the votes shown.
create or replace function lot_tally_rows(farthest text default 'all', group_code text default null)
returns table (parcel_id text, counts int[], timed int, median_seconds numeric, median_pct int, tier text, lead text, display text)
language sql stable security definer set search_path = public as $$
  with allv as materialized (select * from current_votes),
  cv as materialized (select * from allv where lot_tally_rows.group_code is null or allv.group_code = norm_group(lot_tally_rows.group_code)),
  lim as (select coalesce(tier_rank(farthest), 7) as r),
  pop as (select array_agg(allv.seconds_since_prev) as a, count(*) as n from allv where allv.seconds_since_prev is not null),
  g as (
    select cv.parcel_id, tier_rank(cv.tier) as rk, cv.choice, count(*)::int as n
    from cv group by 1, 2, 3
  ),
  lots as (
    select cv.parcel_id,
      count(cv.seconds_since_prev)::int as timed,
      percentile_cont(0.5) within group (order by cv.seconds_since_prev) as med,
      min(tier_rank(cv.tier)) filter (where tier_rank(cv.tier) <= (select r from lim)) as best
    from cv group by cv.parcel_id
  ),
  x as (
    select l.*,
      (select array_agg(coalesce(g.n, 0) order by t.rk, c.i)
         from generate_series(1, 7) t(rk)
         cross join (values ('open_space', 1), ('development', 2), ('yard_expansion', 3)) c(choice, i)
         left join g on g.parcel_id = l.parcel_id and g.rk = t.rk and g.choice = c.choice) as counts,
      (select array_agg(coalesce(g.n, 0) order by c.i)
         from (values ('open_space', 1), ('development', 2), ('yard_expansion', 3)) c(choice, i)
         left join g on g.parcel_id = l.parcel_id and g.rk = l.best and g.choice = c.choice) as k
    from lots l
  )
  select x.parcel_id, x.counts, x.timed, round(x.med::numeric, 1),
    case when x.med is null or (select pop.n from pop) < 2 then null   -- nothing to compare with yet
         else (select round(100.0 * count(*) filter (where s < x.med) / pop.n)::int from pop, unnest(pop.a) s group by pop.n) end,
    (array['lot', 'block', 'neighborhood', 'ward', 'city', 'outside', 'none'])[x.best],
    case
      when x.best is null then null
      when (select count(*) from unnest(x.k) y where y = (select max(z) from unnest(x.k) z)) > 1 then 'tie'
      when x.k[1] >= x.k[2] and x.k[1] >= x.k[3] then 'open_space'
      when x.k[2] >= x.k[3] then 'development'
      else 'yard_expansion'
    end,
    case when x.best is null then null when x.best = 1 then 'solid' else 'hatched' end
  from x
$$;

-- What the public map reads: one jsonb value (no row cap).
-- Lots as [parcel, counts, [timed, median_seconds, median_pct], tier, lead, display].
-- An unknown group code -> {"error": "bad_group"}.
create or replace function lot_tallies(farthest text default 'all', group_code text default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when norm_group(lot_tallies.group_code) is not null and find_group(lot_tallies.group_code) is null
      then jsonb_build_object('error', 'bad_group')
    else jsonb_build_object(
      'farthest', case when tier_rank(farthest) between 1 and 5 then farthest else 'all' end,
      'group_code', find_group(lot_tallies.group_code),
      'rows', coalesce((select jsonb_agg(jsonb_build_array(t.parcel_id, t.counts, jsonb_build_array(t.timed, t.median_seconds, t.median_pct),
                          t.tier, t.lead, t.display))
                        from lot_tally_rows(farthest, find_group(lot_tallies.group_code)) t), '[]'::jsonb))
  end
$$;

-- One voter's current votes: [[parcel, choice, distance_ft, outside_city, tier, group_code], ...]. No timestamps,
-- so a voter ID never turns into a trail of where and when someone was.
create or replace function my_votes(voter_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_array(v.parcel_id, v.choice, v.distance_ft, v.outside_city, v.tier, v.group_code) order by v.parcel_id), '[]'::jsonb)
  from current_votes v where v.voter_id = my_votes.voter_id
$$;

-- A lot's places: {"neighborhood": "Hough", "ward": "Ward 7", "region": "Euclid Corridor/Buckeye"}.
create or replace function lot_info(parcel_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('neighborhood', p.neighborhood, 'ward', p.ward, 'region', p.region)
  from parcels p where p.id = norm_parcel(lot_info.parcel_id)
$$;

-- The public data, for CSV download. Never voter IDs, never a time of day, never group codes.
-- export_lots_for / export_votes_for do the work; g limits them to one group's current votes (null: all).
-- Lots with votes: {parcel, address, neighborhood, ward, region, counts[21], timed, median_seconds, median_pct,
-- tier, lead, display}.
create or replace function export_lots_for(g text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('parcel', p.pin, 'address', p.address, 'neighborhood', p.neighborhood,
           'ward', p.ward, 'region', p.region, 'counts', t.counts, 'timed', t.timed, 'median_seconds', t.median_seconds,
           'median_pct', t.median_pct, 'tier', t.tier, 'lead', t.lead, 'display', t.display) order by p.id), '[]'::jsonb)
  from lot_tally_rows('all', g) t join parcels p on p.id = t.parcel_id
$$;
-- Every current vote: [parcel, address, neighborhood, ward, region, choice, tier, distance_ft, seconds_since_prev,
-- seconds_pct, date, speed_mph, saw_everyone, filter_at_cast, opened_record, location_status], sorted by lot,
-- then choice and tier (not by time). seconds_pct: the share of all timed votes in the record that came sooner
-- after the voter's previous vote. The date is the Cleveland calendar day. speed_mph to one decimal.
create or replace function export_votes_for(g text) returns jsonb
language sql stable security definer set search_path = public as $$
  with v as (
    select cv.*,
      case when cv.seconds_since_prev is null or count(*) over (partition by cv.seconds_since_prev is null) < 2 then null else
        round(100.0 * (rank() over (partition by cv.seconds_since_prev is null order by cv.seconds_since_prev) - 1)
              / count(*) over (partition by cv.seconds_since_prev is null))::int end as seconds_pct
    from current_votes cv
  )
  select coalesce(jsonb_agg(jsonb_build_array(p.pin, p.address, p.neighborhood, p.ward, p.region, v.choice, v.tier,
           v.distance_ft, round(v.seconds_since_prev, 1), v.seconds_pct, to_char(v.created_at at time zone 'America/New_York', 'YYYY-MM-DD'),
           round((v.speed_ms * 2.2369363)::numeric, 1), v.saw_everyone, v.filter_at_cast, v.opened_record, v.location_status)
           order by p.id, v.choice, tier_rank(v.tier), v.distance_ft, v.seconds_since_prev), '[]'::jsonb)
  from v join parcels p on p.id = v.parcel_id
  where g is null or v.group_code = g
$$;
create or replace function export_lots() returns jsonb
language sql stable security definer set search_path = public as $$ select export_lots_for(null) $$;
create or replace function export_votes() returns jsonb
language sql stable security definer set search_path = public as $$ select export_votes_for(null) $$;

-- One group's data: the same files, only that group's current votes. An unknown code -> {"error": "bad_group"}.
create or replace function export_group_lots(code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when find_group(code) is null then jsonb_build_object('error', 'bad_group') else export_lots_for(find_group(code)) end
$$;
create or replace function export_group_votes(code text) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when find_group(code) is null then jsonb_build_object('error', 'bad_group') else export_votes_for(find_group(code)) end
$$;

-- --------------------------------------------------------------- groups
-- A group code helps a block club or coalition gather its votes and see them together. It's for organizing,
-- not evidence: it never changes counts, colors or which votes come first. No names, owners, keys or limits.
--
-- create_group(): a new, unused code: two words and a number from 10 to 99, MAPLE-RIVER-42. Both words come
-- from one fixed list of 1063 short, common words (the EFF short wordlist, trimmed of anything that
-- could read badly, plus nature and neighborhood words), so there are 1063 x 1063 x 90 =
-- 101,697,210 possible codes. Picked with pgcrypto's random bytes.
create or replace function create_group() returns jsonb
language plpgsql volatile security definer set search_path = public, extensions as $$
declare
  w constant text[] := array[
    'acorn', 'acre', 'afar', 'agile', 'aim', 'ajar', 'alive', 'aloe', 'aloft', 'aloha', 'amend', 'ample', 'amuse', 'angel',
    'angle', 'ankle', 'apple', 'april', 'apron', 'aqua', 'area', 'arena', 'aroma', 'array', 'art', 'atlas', 'atom', 'attic',
    'audio', 'awake', 'award', 'axis', 'bacon', 'badge', 'bagel', 'baggy', 'baked', 'baker', 'balmy', 'banjo', 'barge', 'barn',
    'basil', 'bask', 'batch', 'bath', 'baton', 'blank', 'blaze', 'blend', 'bless', 'blimp', 'blink', 'boat', 'body', 'bolt',
    'bonus', 'book', 'booth', 'boxer', 'brick', 'brim', 'bring', 'brink', 'brisk', 'broad', 'broil', 'brook', 'broom', 'brush',
    'bulk', 'bunch', 'bunny', 'bush', 'buzz', 'cable', 'cache', 'calm', 'canal', 'candy', 'cane', 'canon', 'card', 'cargo',
    'carol', 'carry', 'carve', 'cedar', 'chain', 'chair', 'chant', 'charm', 'chef', 'chess', 'chest', 'chili', 'chill', 'chip',
    'chunk', 'churn', 'chute', 'cider', 'cinch', 'city', 'clamp', 'clasp', 'claw', 'clay', 'clean', 'clear', 'cleat', 'click',
    'clink', 'clip', 'cloak', 'clock', 'cloth', 'cloud', 'clump', 'coast', 'coat', 'coil', 'cold', 'colt', 'comic', 'comma',
    'cone', 'coral', 'cork', 'couch', 'cover', 'cozy', 'craft', 'crane', 'crank', 'crate', 'crawl', 'creme', 'crepe', 'crisp',
    'cross', 'crowd', 'crown', 'crumb', 'crust', 'cub', 'curl', 'curry', 'curve', 'cycle', 'dairy', 'daisy', 'dance', 'dandy',
    'dart', 'dawn', 'deck', 'decor', 'dense', 'depth', 'derby', 'desk', 'dial', 'diary', 'dill', 'dime', 'dish', 'disk',
    'dock', 'dome', 'donut', 'dot', 'dove', 'drama', 'dress', 'drift', 'drill', 'drive', 'drone', 'droop', 'drum', 'duck',
    'duo', 'dusk', 'dust', 'dwell', 'eagle', 'early', 'earth', 'east', 'ebony', 'echo', 'edge', 'elbow', 'elder', 'elf',
    'elk', 'elm', 'elves', 'empty', 'emu', 'entry', 'essay', 'fable', 'fall', 'fancy', 'feast', 'fence', 'ferry', 'fiber',
    'film', 'final', 'finch', 'flag', 'flame', 'flap', 'flask', 'flick', 'fling', 'flint', 'flip', 'float', 'flock', 'floss',
    'flyer', 'foam', 'fog', 'foil', 'folk', 'food', 'fox', 'foyer', 'frame', 'fresh', 'frill', 'front', 'frost', 'froth',
    'fruit', 'gala', 'game', 'gear', 'gecko', 'gem', 'genre', 'gift', 'gig', 'glass', 'glide', 'gloss', 'glove', 'glow',
    'glue', 'goal', 'golf', 'gong', 'good', 'grain', 'grape', 'graph', 'grass', 'gray', 'green', 'greet', 'grid', 'grill',
    'grit', 'guide', 'gulf', 'gummy', 'habit', 'half', 'halo', 'happy', 'hatch', 'haven', 'hazel', 'hazy', 'heat', 'hedge',
    'herbs', 'hub', 'icing', 'icon', 'icy', 'igloo', 'image', 'iron', 'ivory', 'ivy', 'jam', 'jazz', 'jelly', 'jet',
    'jog', 'jolly', 'joy', 'juice', 'juicy', 'july', 'jumbo', 'jump', 'kite', 'kiwi', 'koala', 'lake', 'land', 'lasso',
    'latch', 'lemon', 'lens', 'level', 'lever', 'lilac', 'lily', 'limes', 'line', 'lunar', 'malt', 'mango', 'manor', 'map',
    'march', 'match', 'morse', 'motor', 'motto', 'mount', 'mouse', 'movie', 'mulch', 'mural', 'music', 'nacho', 'neon', 'nest',
    'net', 'oak', 'oasis', 'ocean', 'oil', 'olive', 'onion', 'opal', 'open', 'opera', 'otter', 'ounce', 'oval', 'oven',
    'owl', 'ozone', 'palm', 'paper', 'park', 'party', 'pasta', 'patio', 'pecan', 'penny', 'perch', 'petal', 'photo', 'plank',
    'plant', 'plaza', 'plot', 'plow', 'pluck', 'poem', 'poet', 'pogo', 'polar', 'polka', 'polo', 'pond', 'pony', 'poppy',
    'pouch', 'print', 'prism', 'prize', 'prong', 'proof', 'props', 'pug', 'puma', 'puppy', 'purse', 'quiet', 'quill', 'quilt',
    'quote', 'radar', 'radio', 'raft', 'rail', 'rally', 'ramp', 'ranch', 'range', 'raven', 'reach', 'relic', 'rhyme', 'rich',
    'ride', 'ripen', 'river', 'roast', 'robe', 'robin', 'rock', 'romp', 'rope', 'rover', 'ruby', 'rug', 'sage', 'salad',
    'salon', 'salsa', 'salt', 'sandy', 'satin', 'sauna', 'savor', 'sax', 'scale', 'scarf', 'scoop', 'scout', 'scuba', 'sedan',
    'shack', 'shade', 'shady', 'shape', 'share', 'sharp', 'sheep', 'sheet', 'shelf', 'shell', 'shine', 'shiny', 'ship', 'shirt',
    'shop', 'shore', 'showy', 'silk', 'silly', 'silo', 'skate', 'skies', 'skip', 'sky', 'slab', 'slate', 'slaw', 'sled',
    'sleek', 'sleep', 'sleet', 'slice', 'sling', 'smile', 'snack', 'snowy', 'speed', 'spiny', 'spoke', 'spool', 'spoon', 'sport',
    'spot', 'spout', 'spray', 'squad', 'squid', 'stack', 'staff', 'stage', 'stamp', 'start', 'steam', 'steep', 'stem', 'step',
    'stock', 'stony', 'stood', 'storm', 'stout', 'stove', 'straw', 'surf', 'sushi', 'swan', 'swarm', 'sweep', 'swim', 'swing',
    'swirl', 'swoop', 'syrup', 'taco', 'tag', 'tall', 'tart', 'taste', 'tasty', 'thaw', 'thorn', 'thumb', 'tiara', 'tidal',
    'tidy', 'tiger', 'tile', 'tint', 'tiny', 'track', 'train', 'tree', 'trek', 'trio', 'trout', 'truck', 'trunk', 'tulip',
    'turf', 'tutor', 'tweet', 'twine', 'uncle', 'upper', 'urban', 'venue', 'verse', 'vest', 'video', 'visor', 'vocal', 'voice',
    'vowel', 'wafer', 'wagon', 'wand', 'watch', 'water', 'wavy', 'wheat', 'whoop', 'wick', 'wind', 'wing', 'wink', 'wispy',
    'wok', 'wolf', 'wool', 'yam', 'yard', 'yeast', 'yodel', 'yoga', 'zebra', 'zero', 'zesty', 'zippy', 'zone', 'zoom',
    'abacus', 'album', 'amber', 'anchor', 'animal', 'antler', 'anvil', 'atrium', 'avenue', 'awning', 'bakery', 'bamboo', 'banana', 'banner',
    'barley', 'barrel', 'basin', 'basket', 'blazer', 'bobcat', 'bonnet', 'bonsai', 'bottle', 'boxcar', 'breeze', 'breezy', 'bright', 'bronze',
    'brunch', 'bubble', 'bucket', 'buckle', 'bundle', 'cabana', 'cactus', 'camera', 'campus', 'canary', 'candle', 'canopy', 'canyon', 'carbon',
    'carrot', 'carton', 'celery', 'cement', 'cheese', 'chive', 'cinema', 'circle', 'circus', 'citrus', 'clever', 'clover', 'cobalt', 'cocoa',
    'coffee', 'collar', 'collie', 'colony', 'common', 'copper', 'corner', 'cosmos', 'cotton', 'county', 'cradle', 'crayon', 'cymbal', 'daybed',
    'decade', 'delta', 'dinner', 'dollar', 'domain', 'doodle', 'dreamy', 'duffel', 'dugout', 'duvet', 'eatery', 'eclair', 'ember', 'emblem',
    'encore', 'energy', 'engine', 'enamel', 'errand', 'fabric', 'falcon', 'family', 'faucet', 'fedora', 'feline', 'fender', 'ferret', 'fiddle',
    'filter', 'flight', 'floral', 'fondue', 'fossil', 'friday', 'fridge', 'friend', 'fringe', 'frosty', 'frozen', 'galley', 'gallon', 'garage',
    'garden', 'garlic', 'garnet', 'gerbil', 'glade', 'glider', 'gopher', 'gravel', 'groove', 'ground', 'grove', 'gully', 'gusty', 'hamlet',
    'harbor', 'hardy', 'hatbox', 'helmet', 'herbal', 'hubcap', 'humble', 'hummus', 'hybrid', 'iguana', 'jacket', 'jersey', 'jigsaw', 'jingle',
    'jockey', 'jovial', 'joyous', 'judo', 'juggle', 'june', 'junior', 'karate', 'kelp', 'kennel', 'kettle', 'kiln', 'kimono', 'kitten',
    'knoll', 'ladder', 'lagoon', 'laptop', 'lark', 'lather', 'laurel', 'legend', 'liquid', 'lively', 'lizard', 'lumber', 'macaw', 'magma',
    'mammal', 'manila', 'mantis', 'marina', 'marine', 'marlin', 'maroon', 'mascot', 'mauve', 'monday', 'mosaic', 'mossy', 'motion', 'museum',
    'napkin', 'native', 'nature', 'nebula', 'nectar', 'nifty', 'nimble', 'nugget', 'nutmeg', 'nylon', 'oblong', 'oboe', 'ocelot', 'omega',
    'onyx', 'outfit', 'oxford', 'oxygen', 'oyster', 'paddle', 'palace', 'pantry', 'papaya', 'parade', 'parcel', 'parka', 'parlor', 'parrot',
    'pastel', 'pebble', 'pencil', 'petite', 'pleat', 'plenty', 'poncho', 'poplar', 'portal', 'postal', 'primer', 'public', 'pueblo', 'puppet',
    'purple', 'puzzle', 'quail', 'quarry', 'quiver', 'radish', 'raisin', 'ramble', 'ranger', 'ravine', 'ribbon', 'rocket', 'rosy', 'rubber',
    'rudder', 'runner', 'runway', 'rural', 'safari', 'saga', 'sample', 'sandal', 'scenic', 'scone', 'screen', 'scribe', 'scroll', 'sesame',
    'shadow', 'shale', 'shawl', 'shrimp', 'siesta', 'sierra', 'silver', 'simple', 'singer', 'sketch', 'sleeve', 'slogan', 'smooth', 'snazzy',
    'sphere', 'spiral', 'sponge', 'spring', 'sprout', 'spruce', 'sprig', 'squash', 'stable', 'starry', 'statue', 'steed', 'stereo', 'stilt',
    'stitch', 'stream', 'street', 'stucco', 'studio', 'sturdy', 'suburb', 'subway', 'supper', 'swivel', 'tabby', 'tablet', 'tamale', 'tassel',
    'tavern', 'thread', 'thrill', 'thrive', 'tidbit', 'tinsel', 'tiptop', 'tripod', 'trophy', 'trowel', 'turkey', 'turtle', 'tweed', 'twelve',
    'twenty', 'twig', 'upbeat', 'uphill', 'uptown', 'urchin', 'valley', 'velvet', 'vessel', 'violet', 'violin', 'vista', 'voyage', 'waffle',
    'walnut', 'walrus', 'waltz', 'wharf', 'widget', 'willow', 'winter', 'wizard', 'wreath', 'yarn', 'yogurt', 'yonder', 'zodiac', 'maple',
    'birch', 'aspen', 'alder', 'pine', 'fern', 'moss', 'cherry', 'peach', 'plum', 'pear', 'berry', 'melon', 'bean', 'corn',
    'kale', 'beet', 'leek', 'okra', 'windy', 'misty', 'foggy', 'rainy', 'sunny', 'cove', 'bay', 'cliff', 'creek', 'dune',
    'field', 'hill', 'marsh', 'mesa', 'peak', 'ridge', 'shoal', 'slope', 'trail', 'vale', 'bridge', 'tower', 'porch', 'gate',
    'lane', 'road', 'alley', 'block', 'square', 'mill', 'farm', 'bloom', 'seed', 'root', 'leaf', 'bark', 'wren', 'heron',
    'hawk', 'goose', 'deer', 'fawn', 'moose', 'beaver', 'badger', 'rabbit', 'hare', 'bear', 'bison', 'pike', 'carp', 'crab',
    'clam', 'snail', 'moth', 'bee', 'beetle', 'red', 'blue', 'gold', 'rose', 'navy', 'teal', 'jade', 'sand', 'pearl',
    'cream', 'indigo', 'mint', 'honey', 'maize', 'rain', 'snow', 'sun', 'moon', 'star', 'comet', 'noon', 'mist', 'bell',
    'harp', 'flute', 'piano', 'guitar', 'lamp', 'button', 'pocket', 'pillow', 'bike', 'canoe', 'kayak', 'sail', 'oar', 'tram',
    'meadow', 'summer', 'planet', 'tundra', 'pepper', 'teapot', 'cello', 'cashew', 'lantern', 'orchid', 'mocha', 'bread', 'toast', 'muffin',
    'cookie', 'pickle', 'tomato', 'potato', 'apricot', 'iris', 'lotus', 'aster', 'dahlia', 'story', 'riddle', 'rhythm', 'tempo', 'bugle',
    'chime', 'spark', 'beam', 'ray', 'arch', 'spire', 'hearth', 'cabin', 'lodge', 'cottage', 'castle', 'villa', 'terrace'
  ];
  n int := array_length(w, 1);
  b bytea;
  c text;
begin
  for i in 1..50 loop
    b := extensions.gen_random_bytes(12);
    -- 32 random bits per pick; the bias from the remainder is under one in a million.
    c := upper(w[1 + ((get_byte(b, 0)::bigint * 16777216 + get_byte(b, 1) * 65536 + get_byte(b, 2) * 256 + get_byte(b, 3)) % n)]
         || '-' || w[1 + ((get_byte(b, 4)::bigint * 16777216 + get_byte(b, 5) * 65536 + get_byte(b, 6) * 256 + get_byte(b, 7)) % n)])
         || '-' || (10 + (get_byte(b, 8)::bigint * 16777216 + get_byte(b, 9) * 65536 + get_byte(b, 10) * 256 + get_byte(b, 11)) % 90)::text;
    insert into groups (code) values (c) on conflict (code) do nothing;
    if found then return jsonb_build_object('code', c); end if;
  end loop;
  return jsonb_build_object('error', 'no_code');
end $$;

-- Whether a code (as typed: any case, spaces for hyphens) names a group.
create or replace function group_exists(code text) returns boolean
language sql stable security definer set search_path = public as $$
  select find_group(code) is not null
$$;


-- ---------------------------------------------------------------- flags
-- Not stored anywhere: a view, rewritten whenever the rules change. Every number in `rules` is a
-- PLACEHOLDER to be tuned once real votes come in. One row per flagged event and reason.
create or replace view votes_flagged with (security_invoker = true) as
with rules as (
  select
    200            as on_site_ft,      -- PLACEHOLDER: what counts as at the lot for these checks
    40.0::numeric  as max_speed_ms,    -- PLACEHOLDER: faster than this between two lots is implausible travel (m/s)
    30             as burst_votes,     -- PLACEHOLDER: this many events ...
    interval '10 minutes' as burst_window,   -- PLACEHOLDER: ... within this long is a burst
    300            as max_fix_age_s,   -- PLACEHOLDER: an at-the-lot vote from a location fix older than this
    150            as max_accuracy_m   -- PLACEHOLDER: an at-the-lot vote from a fix less precise than this (meters)
), w as (
  select e.*, count(*) over (partition by e.voter_id order by e.created_at
                             range between (select burst_window from rules) preceding and current row) as in_window
  from vote_events e
)
select w.id, w.voter_id, w.parcel_id, w.choice, w.created_at, w.distance_ft, w.seconds_since_prev, w.implied_speed_ms,
       w.gps_accuracy_m, w.fix_age_s, f.reason, w.group_code
from w cross join rules r
cross join lateral (values
  (case when w.distance_ft <= r.on_site_ft and w.implied_speed_ms > r.max_speed_ms then 'implied_travel' end),
  (case when w.in_window >= r.burst_votes then 'burst' end),
  (case when w.distance_ft <= r.on_site_ft and w.fix_age_s > r.max_fix_age_s then 'stale_fix' end),
  (case when w.distance_ft <= r.on_site_ft and w.gps_accuracy_m > r.max_accuracy_m then 'weak_fix' end)
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

-- Each lot's neighborhood, ward and region: the place containing its centroid (or, failing that, the one
-- overlapping it most).
create or replace function assign_places() returns int
language plpgsql security definer set search_path = public, extensions as $$
declare n int;
begin
  update parcels p set
    neighborhood = coalesce(
      (select x.name from places x where x.kind = 'neighborhood' and st_covers(x.geom, p.center::extensions.geometry) order by x.name limit 1),
      (select x.name from places x where x.kind = 'neighborhood' and st_intersects(x.geom, p.geom::extensions.geometry)
         order by st_area(st_intersection(x.geom, p.geom::extensions.geometry)) desc limit 1)),
    ward = coalesce(
      (select x.name from places x where x.kind = 'ward' and st_covers(x.geom, p.center::extensions.geometry) order by x.name limit 1),
      (select x.name from places x where x.kind = 'ward' and st_intersects(x.geom, p.geom::extensions.geometry)
         order by st_area(st_intersection(x.geom, p.geom::extensions.geometry)) desc limit 1)),
    region = coalesce(
      (select x.name from places x where x.kind = 'region' and st_covers(x.geom, p.center::extensions.geometry) order by x.name limit 1),
      (select x.name from places x where x.kind = 'region' and st_intersects(x.geom, p.geom::extensions.geometry)
         order by st_area(st_intersection(x.geom, p.geom::extensions.geometry)) desc limit 1))
  where p.id is not null;
  get diagnostics n = row_count;
  return n;
end $$;

-- Loads the neighborhoods, wards and regions from the city, then reassigns every lot.
create or replace function sync_places() returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare s place_sources; n int; res jsonb := '{}'::jsonb;
begin
  for s in select * from place_sources order by kind loop
    begin
      insert into places (kind, name, geom, attrs, loaded_at)
        select s.kind, x.nm, st_multi(st_union(x.g)), jsonb_agg(x.props), now()
        from (
          select case when s.title_case then initcap(trim(f #>> array['properties', s.name_field]))
                      else trim(f #>> array['properties', s.name_field]) end as nm,
                 to_multipolygon(f -> 'geometry') as g, f -> 'properties' as props
          from jsonb_array_elements(city_get(s.url || '/query?where=1%3D1&outFields=*&returnGeometry=true&outSR=4326&geometryPrecision=6&f=geojson') -> 'features') f
          where jsonb_typeof(f -> 'geometry') = 'object'
        ) x
        where x.nm is not null and x.nm <> '' and x.g is not null
        group by x.nm
      on conflict (kind, name) do update set geom = excluded.geom, attrs = excluded.attrs, loaded_at = now();
      get diagnostics n = row_count;
      res := res || jsonb_build_object(s.kind, n);
    exception when others then
      res := res || jsonb_build_object(s.kind, sqlerrm);
    end;
  end loop;
  return res || jsonb_build_object('lots', assign_places());
end $$;

-- Brings parcels in line with the city's published inventory, shapes included. Checks the layer's last-edit
-- date first and stops there if nothing changed. Lots the city no longer publishes are archived with their
-- votes. Refuses (and changes nothing) if the city returns far fewer lots than expected; sync_city(true) overrides.
-- Also reloads the city boundary and the neighborhoods, wards and regions when they're over 30 days old.
create or replace function sync_city(p_force boolean default false)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s sync_settings; meta jsonb; edit bigint; cnt int; size int; off int := 0; q text;
  feats jsonb := '[]'::jsonb; seen parcels[]; ids text[];
  got int; cur int; added int; relisted int; archived int; res jsonb; b jsonb; pl jsonb;
begin
  select * into s from sync_settings;
  update sync_settings set last_run = now() where id;
  begin
    if not exists (select 1 from city_boundary where loaded_at > now() - interval '30 days') then
      begin b := sync_boundary(); exception when others then b := jsonb_build_object('status', 'failed', 'error', sqlerrm); end;
    end if;
    if not exists (select 1 from places where loaded_at > now() - interval '30 days') then
      begin pl := sync_places(); exception when others then pl := jsonb_build_object('status', 'failed', 'error', sqlerrm); end;
    end if;

    meta := city_get(s.layer_url || '?f=json');
    edit := coalesce(meta #>> '{editingInfo,dataLastEditDate}', meta #>> '{editingInfo,lastEditDate}')::bigint;
    if not p_force and edit is not null and edit = s.last_edit and s.last_ok is not null then
      res := jsonb_build_object('status', 'unchanged', 'edited', edit, 'boundary', b, 'places', pl);
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
                         'public', now(), now(), null, null, null, null)::parcels), array_agg(x.id)
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
      res := jsonb_build_object('status', 'refused', 'edited', edit, 'boundary', b, 'places', pl, 'reason',
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
    perform assign_places();

    res := jsonb_build_object('status', 'synced', 'edited', edit, 'public', got, 'added', added,
                              'relisted', relisted, 'archived', archived, 'boundary', b, 'places', pl);
    update sync_settings set last_edit = edit, last_ok = now(), last_result = res where id;
    return res;
  exception when others then
    res := jsonb_build_object('status', 'failed', 'error', sqlerrm, 'boundary', b, 'places', pl);
    update sync_settings set last_result = res where id;
    return res;
  end;
end $$;


-- ------------------------------------------------------------------ access
-- The public (anon) can't read or write any table or view. It can call ten functions.

alter table parcels       enable row level security;
alter table city_boundary enable row level security;
alter table sync_settings enable row level security;
alter table place_sources enable row level security;
alter table places        enable row level security;
alter table cards         enable row level security;
alter table vote_events   enable row level security;
alter table groups        enable row level security;

revoke all on parcels, city_boundary, sync_settings, place_sources, places, cards, vote_events, groups from anon, authenticated;
revoke all on current_votes, votes_flagged from anon, authenticated;

do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function cast_vote(uuid, text, text, double precision, double precision, double precision, double precision,
  double precision, text, boolean, text, text, boolean, boolean, text, text, text, text) to anon, authenticated;
grant execute on function lot_tallies(text, text)      to anon, authenticated;
grant execute on function my_votes(uuid)               to anon, authenticated;
grant execute on function lot_info(text)               to anon, authenticated;
grant execute on function export_lots()                to anon, authenticated;
grant execute on function export_votes()               to anon, authenticated;
grant execute on function create_group()               to anon, authenticated;
grant execute on function group_exists(text)           to anon, authenticated;
grant execute on function export_group_lots(text)      to anon, authenticated;
grant execute on function export_group_votes(text)     to anon, authenticated;


-- ----------------------------------------- schedule the sync

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('city-sync', '17 * * * *', 'select public.sync_city()');
  end if;
end $$;

-- First load (16,000+ lot shapes): run   select sync_city();   by itself after this file.
-- Neighborhoods, wards and regions:      select sync_places();   (sync_city also runs it monthly)
-- How the last sync went:                select last_run, last_result from sync_settings;
