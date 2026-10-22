# Public Land Voting Tool: proximity version

Owner: Tim (Planning and Design Specialist, Western Reserve Land Conservancy). This is a new build, separate from the coalition-maps tool (`timothydehm/public-land-vote` + Supabase `parcel-vote`), which stays as it is. The product name is still **Public Land Voting Tool**. Don't use "Ballot".

- Repo: `timothydehm/public-land-record`, GitHub Pages from `main` / root → https://timothydehm.github.io/public-land-record/
- Supabase project: `public-land-record` (ref `seqjjbvfeosqpmwmivkt`, us-east-1, free plan, org `timothydehm`).

## Where things stand (Oct 22, 2026, third round)

- **Live now:** version 2 (Tim ran `schema.sql` and uploaded `index.html`): feet; where-cast tiers from distance plus the city's neighborhood and ward boundaries; nearest tier sets the color; "Show votes cast" filter; Share the map; Download the data. The record has Tim's test votes (27 events on Oct 22).
- **Built and tested, waiting on Tim:** timing without cutoffs (Tim, Oct 22: "I don't like arbitrary measurements"). The rapid/steady/unhurried labels (`vote_pace`, 10 s / 2 min cutoffs) are gone. Each vote keeps its raw `seconds_since_prev`; the card shows a lot's median compared with every vote in the record ("longer than 70% of votes"); the CSVs publish each vote's seconds and the comparison. No new measurement was added (Tim declined a "time on the lot" measure).
- **To go live:** (1) run the whole `schema.sql` in the Supabase SQL editor again (rerunnable; drops the `current_votes` view's `pace` column, `vote_pace()` and the old `lot_tally_rows`, and recreates them). (2) Upload the new `index.html` right after; the version 2 page reads the old tally shape. Claude can't apply drops through the Supabase connector without an approval, which times out unattended.
- **Printed cards:** `tools/make_cards.py`, run locally with the project's secret key. Unchanged.

## Purpose and principle

A public, parcel-keyed record of what people want for city-owned vacant land, built to hold decision-makers accountable. It's meant to pair with community engagement, not replace it.

**No gates, just evidence.** Anyone can vote on any lot. No codes, sign-ups, or budgets. Each vote records how it was cast (distance from the parcel, whether it was cast inside the lot's neighborhood and ward, timing), and display rules decide how much it counts. Only raw measurements are stored; no threshold is written into stored data. Every threshold lives in a function argument or a view and can change without touching the record. The rules are public ("How votes count" page).

Removed from the previous tool, on purpose: multiple/coalition maps, map leaders and leader codes, invite codes and organizer keys, vote budgets, map deletion, share-with-decision-makers and its sent log.

## The map (index.html)

One file, plain HTML/CSS/JS. MapLibre GL 4.7.1 from jsdelivr; qrcode-generator 1.4.4 from cdnjs (loaded only for the voter card). No supabase-js: the page calls the six RPCs with `fetch` POST (`rpc()`), so coordinates are always in a request body, never in a URL.

- **Copied from the previous tool:** the lot loading (`loadParcels`, `buildParcels`, labels for lots without addresses, IndexedDB cache keyed by the city's edit date), the map setup (white paper + Esri imagery at 0.5 opacity, desaturated; OpenFreeMap positron street names on top; white lot outlines; dots below zoom 15; pink selection outline), the parcel card's city fields (every field the layer publishes, aliases as labels, blanks shown as "Blank", folded under "City record"), and the colors (open space `#00875F`, development `#0068A6`, yard expansion `#E6A200`).
- **Three fixed choices** (`CHOICES`): `open_space`, `development`, `yard_expansion`. Keys are stored; labels can change.
- **Where a vote was cast (tiers, nearest first)** (Tim, Oct 22): at the lot (≤200 ft, "on site"), on the block (≤500 ft), in the lot's neighborhood (city SPA boundaries), in the lot's ward, elsewhere in Cleveland, outside Cleveland, no location. Computed by `vote_tier()` in the database from the stored distance and two yes/no answers; `TIERS` in the page has the labels ("In Hough", "In Ward 7").
- **Display precedence** (Tim, Oct 22: nearest tier decides; replaces on-site vs off-site): on each lot, the nearest tier that has votes sets the color by its leading choice. Solid if that tier is "at the lot", hatched otherwise, plain with no votes. **Ties are grey** (`TIE`, `#8A8781`) (Tim, Oct 22). Computed server-side in `lot_tally_rows`. Hatching is a MapLibre `fill-pattern` (`h-<key>` images drawn on a canvas in `hatchImage`). Zoomed out: filled dot = solid, ring = hatched.
- **Units:** feet and miles everywhere (Tim, Oct 22). `fmtDist`: "130 ft" under 1,000 ft, then "0.4 mi".
- **Voting:** tap a lot (zoom ≥ 15) for the compact card, then a choice square in the bottom bar. Tap the active choice to clear; another to change. One lot at a time, on purpose. Optimistic on screen; each tap is one `cast_vote` with the latest location fix; saves on one lot go out in order; a failed save reverts with a message. Keys 1/2/3 vote, Esc closes.
- **Card:** address label, parcel number, the lot's neighborhood · ward · planning region (`lot_info`), one row per tier that has votes ("At the lot: 3 open space, 1 yard expansion", "In Hough: 2 development"; the deciding tier bold, tiers outside the current filter dimmed), a Timing line ("median 14 s after the voter's previous vote · longer than 62% of votes"; one timed vote drops "median"; no comparison until the record has two timed votes; "each vote was the voter's first" when none are timed), and "Your vote: Development · 340 ft away, on the block" (or "at the lot", "no location", "from outside Cleveland", "saving…").
- **Bottom bar:** three choice squares (labeled), your-votes / everyone's-votes toggle (person icon), More (⋯).
- **More:** color/solid/hatched key; **Show votes cast** chips: At the lot / On the block / In the neighborhood / In the ward / In Cleveland / From anywhere (default; remembered per browser), with "Changes only what you see, not the votes. On every lot, the votes cast closest to it set its color." It re-asks `lot_tallies(farthest)` and repaints (Tim found the old meters slider unclear about whether it set what counts as close or just changed the view; the chips are a view filter only). Then Use my location (if not on), Share the map, Your voter card, Download the data, How votes count. A tap on the map folds More away.
- **Your votes view:** your current votes only, solid if cast at the lot, hatched otherwise; the filter applies.
- **Share the map** (Tim, Oct 22: keep it general): the plain page address (never a card link), through the phone's share sheet if there is one, otherwise copied ("Link to the map copied"). Routing to council members, CDCs and planners is for later; the lot's ward and planning region (with the region's planner in `places.attrs`) are already in the database for it.
- **Timing** (Tim, Oct 22: not travel; "is this person thinking about the decisions or just plugging away"; then "I don't like arbitrary measurements… track the time between and that can be analyzed afterwards"): the measurement is `seconds_since_prev` (ms precision, since the voter's previous event on any lot). Its reference figure, like the lot and boundaries are for distance, is the record itself: the share of all current timed votes that came sooner (`median_pct` per lot, `seconds_pct` per vote in the export). No cutoffs, nothing stored; the comparison shifts as votes come in. First votes (no previous) are left out of the comparison. Doesn't change colors; no map filter. Implied travel speed is still stored and used only by `votes_flagged`. Known blur: for someone walking lot to lot the gap is mostly walking; Tim chose not to add a separate time-on-the-lot measure.
- **Download the data** (`#/data`, anyone): two CSVs, no voter IDs and no time of day (Tim, Oct 22). "Votes by lot": one row per lot with votes (parcel, address, neighborhood, ward, planning region, total, 21 counts `<tier>_<choice>`, votes_with_timing, median_seconds_since_voters_previous_vote, median_longer_than_pct_of_votes, closest tier, leading choice, map style). "Every vote": one row per current vote (parcel, address, neighborhood, ward, region, choice, cast_from, distance_ft, seconds_since_voters_previous_vote, longer_than_pct_of_votes, date), sorted by lot, not time. UTF-8 with BOM so Excel opens it cleanly.
- **Refresh:** tallies and your votes every 20 s while visible (`CONFIG.refreshSeconds`), skipped while a save is pending.
- **Pages** (hash routes over the map): `#/card` (Your voter card), `#/data` (Download the data), `#/how` (How votes count, rewritten for tiers, nearest-tier precedence, the filter, timing, feet, and the neighborhood/ward yes/no).

### Identity

- Device ID: random UUID in localStorage (`plvt:voter-id`) on first visit. No personal data.
- Card link `…/?card=<uuid>`: adopted as the device's ID, then the parameter is stripped from the address bar. If the device already has votes under a different ID, it asks once (Switch to the card / Copy this device's link / Keep this device's). A malformed card link is refused with a message.
- Your voter card: QR of the card link, **Copy link** right under it, and one line: "Save this link or screenshot the code to get your votes back on any device. Anyone with it can vote as you." Self-made cards have no batch tag (they aren't in `cards`).
- Later, not now: "Restore from image" (jsQR) and passkeys holding the same ID.

### Location

- Before the browser's prompt, one sentence in a sheet: "Your location shows whether you're at the lot. We keep the distance, not where you are." (Use my location / Not now). Already granted → no sheet. Answered "Use my location" before → no sheet again. "Not now" → no sheet again; the locate button or More > Use my location brings it back.
- `watchPosition` (high accuracy) while open; the map opens on the voter's first fix if it's in Cleveland, otherwise stays on the city. A blue dot shows the position (never saved).
- No fix or declined: the vote is still recorded with null distance and falls in the "no location" tier.

## The database (schema.sql)

Run in the Supabase SQL editor; rerunnable. **Applying through the Supabase connector:** statements the connector considers destructive (any `drop`, `delete`, `update` without `where`) wait for an approval and time out if nobody's there. That's why `sync_city` uses arrays instead of a temp table and every `sync_settings` update has `where id`.

- `parcels` (id = parcel number, letters and digits only, uppercase; pin; address; category; `geom` geography MultiPolygon; `center` centroid; status public/archived), synced hourly by `sync_city()` from the city's land bank layer (`f=geojson`, shapes included). Lots the city stops publishing are archived, never deleted. Refuses a sync that returns far fewer lots than expected (`sync_city(true)` overrides).
- `city_boundary`: union of the 2026 ward polygons, reloaded by `sync_city` when older than 30 days (`sync_boundary()`).
- `places` (kind neighborhood/ward/region, name, geom, attrs = the city's fields per source polygon, e.g. a region's planner and email) from `place_sources`: SPA neighborhoods (`Cleveland_SPA_Neighborhoods_Salesforce`, field `SPANM`, 34), 2026 wards (`NAME`, 15), design review regions (clevelandgis.org `PlanningWAB/MapServer/98`, `REGION`, title-cased, 6; "Downtown/Flats" is two polygons merged). `sync_places()` loads them and runs `assign_places()`, which sets each lot's `neighborhood`, `ward`, `region` (centroid, else largest overlap). `sync_city` reruns `sync_places` when places are over 30 days old and `assign_places` after every sync that changes lots.
- `sync_settings`: layer URLs and the last result (`select last_run, last_result from sync_settings;`).
- `vote_events` (append-only, trigger-enforced; every cast, change and clear): `voter_id`, `parcel_id`, `choice` (null = clear), `created_at`, `distance_ft` (rounded), `outside_city`, `in_neighborhood`, `in_ward` (yes/no: was the voter inside the lot's neighborhood / ward; null when unknown), `gps_accuracy_m`, `fix_age_s`, `seconds_since_prev`, `implied_speed_ms`. To erase test rows on purpose: `begin; set local app.erase_votes = 'yes'; delete from vote_events where …; commit;`
- `cards` (`id` uuid, `batch_tag`, `created_at`): printed cards. Provenance only; private.
- `cast_vote(voter_id, parcel_id, choice, lat, lng, accuracy_m, fix_age_s)`, `security definer`, PostGIS geography. Distance from the point to the lot polygon (0 inside), in feet, rounded (`round_distance_ft`): under 1,000 ft → nearest 10 ft; 1,000 ft–2 mi → nearest 100 ft; beyond → nearest half mile; outside the city boundary → `outside_city = true`, no distance, both yes/no false. Inside the city it also checks the point against the lot's neighborhood and ward polygons. Returns the vote's `tier`. Coordinates are discarded and never stored. The function sets `log_parameter_max_length_on_error = 0`; nothing in it raises with coordinates; the project's `log_min_duration_statement` is off. `seconds_since_prev` from the voter's previous event on any lot; `implied_speed_ms` = centroid-to-centroid distance between the two lots ÷ the exact elapsed time (capped to fit the column). A per-voter advisory lock keeps one voter's events in order. A clear with nothing to clear writes nothing. Errors come back as `{"error": "no_voter" | "bad_choice" | "parcel_not_found"}`.
- `current_votes` (view): latest event per voter × lot, without clears, plus `tier`. A vote's tier is that of its *latest* cast, so a remote voter who later goes to the lot can clear and re-cast to make it on-site.
- `vote_tier(distance_ft, outside_city, in_neighborhood, in_ward)`, `tier_rank(tier)`: the rules, in one place each.
- `lot_tally_rows(farthest)` / `lot_tallies(farthest)` (public; one jsonb value, no row cap): per lot `[parcel, counts[21] (tier-major: lot, block, neighborhood, ward, city, outside, none × open space, development, yard expansion), [timed, median_seconds, median_pct], tier, lead, display]`. `median_pct` = share (0–100) of all current timed votes with a shorter `seconds_since_prev` than the lot's median (null until two timed votes exist). `lot_tally_rows` materializes `current_votes` once. `farthest` limits which tiers count toward the color (`lot`…`city`, or `all`); counts always include every tier.
- `my_votes(voter_id)`: `[[parcel, choice, distance_ft, outside_city, tier], …]`. No timestamps, so an ID never becomes a trail of movements.
- `lot_info(parcel_id)`: `{neighborhood, ward, region}`.
- `export_lots()`, `export_votes()`: the CSV data (no IDs, no time of day; votes sorted by lot).
- `votes_flagged` (view, not public): one row per flagged event and reason: `implied_travel`, `burst`, `stale_fix`, `weak_fix`. Every threshold is in its `rules` CTE marked PLACEHOLDER (40 m/s, 30 events in 10 min, fix older than 300 s, accuracy worse than 150 m, at the lot = 200 ft). Flags are never stored; rewrite the view to change them. The map doesn't use flags yet.
- **Access:** RLS on every table, no policies; anon/authenticated can't read or write any table or view. They can execute only `cast_vote`, `lot_tallies`, `my_votes`, `lot_info`, `export_lots`, `export_votes`. The Supabase security advisor lists these as public security-definer functions; that's intended.

## Printed cards (tools/make_cards.py)

Python 3.8+, standard library only. `python make_cards.py --count 40 --tag "Glenville block club, Nov"`. Asks for the secret key (or reads `SUPABASE_SECRET_KEY`), inserts N rows into `cards` with the tag, and writes `cards-<tag>-<date>.html`: a letter-size sheet, 3 across, dashed cut lines, a QR per card (`…/?card=<id>`) and one line of text. Open it in a browser and print. The tag isn't printed or put in the link, so it can't be forged.

## Known limits

- Location comes from the voter's browser; a determined person can fake coordinates. The record keeps accuracy, fix age and implied travel so `votes_flagged` can catch patterns, but nothing blocks a vote.
- Anyone can mint new IDs. That's by design: unlimited remote votes still can't override one closer vote.
- A voter standing just outside the city line (e.g. across the street in East Cleveland) is "outside Cleveland" with no distance.
- Neighborhoods and wards don't nest; a vote inside the lot's ward but outside its neighborhood is "in the ward". 3 lots have no neighborhood (gaps in the city's layer), so votes on them skip that tier.
- `my_votes` answers for any ID it's given; the ID is the secret.

## Testing approach

- Timing (Oct 22, third round): local upgrade from version 2 and a fresh install; SQL checks of median, per-vote and per-lot percentages against hand-computed values (4 timed votes: 0.051, 0.055, 0.314, 1.203 s → 0/25/50/75%); Playwright suite (25 checks) with the timing line and the new CSV columns.

- Version 2 (Oct 22): local database upgraded from the Oct 21 schema (meters converted to feet) and the file rerun; fixture places (two neighborhoods, two wards, one region over the 320-lot grid). SQL as `anon`: every tier (lot, block 340 ft, neighborhood, ward, city, outside, none), nearest-tier precedence and each filter, clear → next tier decides, my_votes with tier, lot_info, both exports, pace thresholds. Playwright (24 checks): card rows by tier with "In Hough", deciding tier marked, feet ("340 ft away, on the block", "0.3 mi away, in Hough"), place line, block-only lot hatched, pace "1 rapid", filter chips re-query and hide/restore lots and explain a filtered-out lot, your-votes view honors the filter, no-location tier, neighborhood vote outranks no-location, Share copies the plain map link, both CSV downloads (rows, no IDs), How page; plus the Oct 21 suite (card links, voter card, location note, outside city, keyboard, failed save) still passing.

### Oct 21

- SQL: local Postgres 16 + PostGIS 3.4 with Supabase-like roles; every function as `anon` (inside, near, far, outside city, no location, clear/no-op clear, bad choice/parcel, tallies at two thresholds incl. ties, my_votes, permission denials on tables/views/sync, append-only trigger, rounding bands, flags). The same checks against the live project inside a rolled-back DO block.
- Page: Playwright (Chromium, SwiftShader) against a local copy of the page, with the city layer routed to a 320-lot synthetic fixture and RPCs routed into the local database as `anon`. 30 checks: pre-prompt sentence and Not now, null-distance vote, hatched off-site lot, ID survives reload, voter card QR + Copy link, How votes count, on-site vote beats off-site (solid), dual counts on the card, slider re-query and repaint, your-votes view, outside-city flag, card link adoption (fresh device, ask on conflict, keep, switch, bad link, parameter stripped), desktop layout, keyboard voting, failed save reverts, every call POST with nothing in the URL. Card sheet: generated against a mock API, printed QR decoded with jsQR and opened on a phone → adopted.
- The session's network can't reach the city's ArcGIS service, Supabase's API, or the CDNs, so the hosted page itself hasn't been opened yet. First check after publishing: lots load, a vote at a real lot comes back "at the lot (on site)".

## Design rules

- Simple, sleek, doesn't look AI-generated. One typeface (Public Sans), plain sentence-case copy, no decoration that doesn't carry information.
- Only votes: no comments or free text.

## Working with Tim

- Direct, no flattery; commit and iterate rather than over-analyze.
- No timeline estimates unless he asks.
- Ask before creating things he didn't request; when he says build, build fully and test.
- Open decisions get asked, not assumed.
