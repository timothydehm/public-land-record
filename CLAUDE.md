# Public Land Voting Tool: proximity version

Owner: Tim (Planning and Design Specialist, Western Reserve Land Conservancy). This is a new build, separate from the coalition-maps tool (`timothydehm/public-land-vote` + Supabase `parcel-vote`), which stays as it is. The product name is still **Public Land Voting Tool**. Don't use "Ballot".

- Repo: `timothydehm/public-land-record`, GitHub Pages from `main` / root → https://timothydehm.github.io/public-land-record/
- Supabase project: `public-land-record` (ref `seqjjbvfeosqpmwmivkt`, us-east-1, free plan, org `timothydehm`).

## Where things stand (Oct 22, 2026)

- **Database: live and complete.** Schema applied, first city sync done (16,445 lots with shapes, city boundary from the 2026 wards), hourly `city-sync` cron at :17. No votes in the record: every test against the live project ran inside a transaction that rolled back.
- **Page: built and tested, not yet published.** Claude can't create repos or push from its session. Tim creates the repo, uploads `index.html` to the root, and turns on Pages (Settings > Pages > Deploy from a branch > `main` / root). `schema.sql`, `CLAUDE.md` and `tools/` can go up too; only `index.html` is served.
- **Printed cards:** `tools/make_cards.py`, run locally with the project's secret key.

## Purpose and principle

A public, parcel-keyed record of what people want for city-owned vacant land, built to hold decision-makers accountable. It's meant to pair with community engagement, not replace it.

**No gates, just evidence.** Anyone can vote on any lot. No codes, sign-ups, or budgets. Each vote records how it was cast (distance from the parcel, timing), and display rules decide how much it counts. Only raw measurements are stored; no threshold is written into stored data. Every threshold lives in a function argument or a view and can change without touching the record. The rules are public ("How votes count" page).

Removed from the previous tool, on purpose: multiple/coalition maps, map leaders and leader codes, invite codes and organizer keys, vote budgets, map deletion, share-with-decision-makers and its sent log.

## The map (index.html)

One file, plain HTML/CSS/JS. MapLibre GL 4.7.1 from jsdelivr; qrcode-generator 1.4.4 from cdnjs (loaded only for the voter card). No supabase-js: the page calls the three RPCs with `fetch` POST (`rpc()`), so coordinates are always in a request body, never in a URL.

- **Copied from the previous tool:** the lot loading (`loadParcels`, `buildParcels`, labels for lots without addresses, IndexedDB cache keyed by the city's edit date), the map setup (white paper + Esri imagery at 0.5 opacity, desaturated; OpenFreeMap positron street names on top; white lot outlines; dots below zoom 15; pink selection outline), the parcel card's city fields (every field the layer publishes, aliases as labels, blanks shown as "Blank", folded under "City record"), and the colors (open space `#00875F`, development `#0068A6`, yard expansion `#E6A200`).
- **Three fixed choices** (`CHOICES`): `open_space`, `development`, `yard_expansion`. Keys are stored; labels can change.
- **Display precedence** (server computes it in `parcel_tally_rows`): ≥1 on-site vote → solid, leading on-site choice; only off-site votes → hatched, leading off-site choice; none → plain. **Ties are grey** (`TIE`, `#8A8781`), solid or hatched by the same rule (Tim, Oct 22). Hatching is a MapLibre `fill-pattern` (`h-<key>` images drawn on a canvas in `hatchImage`). Zoomed out: filled dot = solid, ring = hatched.
- **Voting:** tap a lot (zoom ≥ 15) for the compact card, then a choice square in the bottom bar. Tap the active choice to clear; another to change. One lot at a time, on purpose. Optimistic on screen; each tap is one `cast_vote` with the latest location fix; saves on one lot go out in order; a failed save reverts with a message. Keys 1/2/3 vote, Esc closes.
- **Card:** address label, parcel number, "On site: …" and "Off site: …" counts by choice at the current threshold, and "Your vote: Open space · 40 m away (on site)" (or "no location", "from outside the city", "saving…").
- **Bottom bar:** three choice squares (labeled), your-votes / everyone's-votes toggle (person icon), More (⋯).
- **More:** color/solid/hatched key; "On site within ___ m" slider (25 / 50 / 100 / 250, default 100, remembered per browser) which re-asks `parcel_tallies(on_site_m)` and repaints live; "Use my location" (if not on); Your voter card; How votes count. A tap on the map folds More away.
- **Your votes view:** your current votes only, solid if your distance is within the slider's threshold, hatched otherwise.
- **Refresh:** tallies and your votes every 20 s while visible (`CONFIG.refreshSeconds`), skipped while a save is pending.
- **Pages** (hash routes over the map): `#/card` (Your voter card), `#/how` (How votes count).

### Identity

- Device ID: random UUID in localStorage (`plvt:voter-id`) on first visit. No personal data.
- Card link `…/?card=<uuid>`: adopted as the device's ID, then the parameter is stripped from the address bar. If the device already has votes under a different ID, it asks once (Switch to the card / Copy this device's link / Keep this device's). A malformed card link is refused with a message.
- Your voter card: QR of the card link, **Copy link** right under it, and one line: "Save this link or screenshot the code to get your votes back on any device. Anyone with it can vote as you." Self-made cards have no batch tag (they aren't in `cards`).
- Later, not now: "Restore from image" (jsQR) and passkeys holding the same ID.

### Location

- Before the browser's prompt, one sentence in a sheet: "Your location shows whether you're at the lot. We keep the distance, not where you are." (Use my location / Not now). Already granted → no sheet. Answered "Use my location" before → no sheet again. "Not now" → no sheet again; the locate button or More > Use my location brings it back.
- `watchPosition` (high accuracy) while open; the map opens on the voter's first fix if it's in Cleveland, otherwise stays on the city. A blue dot shows the position (never saved).
- No fix or declined: the vote is still recorded with null distance and counts as off-site.

## The database (schema.sql)

Run in the Supabase SQL editor; rerunnable. **Applying through the Supabase connector:** statements the connector considers destructive (any `drop`, `delete`, `update` without `where`) wait for an approval and time out if nobody's there. That's why `sync_city` uses arrays instead of a temp table and every `sync_settings` update has `where id`.

- `parcels` (id = parcel number, letters and digits only, uppercase; pin; address; category; `geom` geography MultiPolygon; `center` centroid; status public/archived), synced hourly by `sync_city()` from the city's land bank layer (`f=geojson`, shapes included). Lots the city stops publishing are archived, never deleted. Refuses a sync that returns far fewer lots than expected (`sync_city(true)` overrides).
- `city_boundary`: union of the 2026 ward polygons, reloaded by `sync_city` when older than 30 days (`sync_boundary()`).
- `sync_settings`: layer URLs and the last result (`select last_run, last_result from sync_settings;`).
- `vote_events` (append-only, trigger-enforced; every cast, change and clear): `voter_id`, `parcel_id`, `choice` (null = clear), `created_at`, `distance_m` (rounded), `outside_city`, `gps_accuracy_m`, `fix_age_s`, `seconds_since_prev`, `implied_speed_ms`. To erase test rows on purpose: `begin; set local app.erase_votes = 'yes'; delete from vote_events where …; commit;`
- `cards` (`id` uuid, `batch_tag`, `created_at`): printed cards. Provenance only; private.
- `cast_vote(voter_id, parcel_id, choice, lat, lng, accuracy_m, fix_age_s)`, `security definer`, PostGIS geography. Distance from the point to the lot polygon (0 inside), rounded: under 200 m → nearest 10 m; 200 m–2 km → nearest 100 m; over 2 km → nearest 1 km; outside the city boundary → `outside_city = true`, no distance. Coordinates are discarded and never stored. The function sets `log_parameter_max_length_on_error = 0`; nothing in it raises with coordinates; the project's `log_min_duration_statement` is off. `seconds_since_prev` from the voter's previous event on any lot; `implied_speed_ms` = centroid-to-centroid distance between the two lots ÷ the exact elapsed time (capped to fit the column). A per-voter advisory lock keeps one voter's events in order. A clear with nothing to clear writes nothing. Errors come back as `{"error": "no_voter" | "bad_choice" | "parcel_not_found"}`.
- `current_votes` (view): latest event per voter × lot, without clears. Note: a vote's distance is the distance of its *latest* cast, so a remote voter who later goes to the lot can clear and re-cast to make it on-site.
- `parcel_tally_rows(on_site_m)` / `parcel_tallies(on_site_m)` (the public one returns one jsonb value, no row cap): per lot `[parcel, on×3, off×3, display, lead]`. On site = distance ≤ `on_site_m`; null distance or outside the city = off site.
- `my_votes(voter_id)`: `[[parcel, choice, distance_m, outside_city], …]`. No timestamps, so an ID never becomes a trail of movements.
- `votes_flagged` (view, not public): one row per flagged event and reason: `implied_travel`, `burst`, `stale_fix`, `weak_fix`. Every threshold is in its `rules` CTE marked PLACEHOLDER (40 m/s, 30 events in 10 min, fix older than 300 s, accuracy worse than 150 m, on site = 100 m). Flags are never stored; rewrite the view to change them. The map doesn't use flags yet.
- **Access:** RLS on every table, no policies; anon/authenticated can't read or write any table or view. They can execute only `cast_vote`, `parcel_tallies`, `my_votes`. The Supabase security advisor lists exactly these three as public security-definer functions; that's intended.

## Printed cards (tools/make_cards.py)

Python 3.8+, standard library only. `python make_cards.py --count 40 --tag "Glenville block club, Nov"`. Asks for the secret key (or reads `SUPABASE_SECRET_KEY`), inserts N rows into `cards` with the tag, and writes `cards-<tag>-<date>.html`: a letter-size sheet, 3 across, dashed cut lines, a QR per card (`…/?card=<id>`) and one line of text. Open it in a browser and print. The tag isn't printed or put in the link, so it can't be forged.

## Known limits

- Location comes from the voter's browser; a determined person can fake coordinates. The record keeps accuracy, fix age and implied travel so `votes_flagged` can catch patterns, but nothing blocks a vote.
- Anyone can mint new IDs. That's by design: unlimited remote votes still can't override one on-site vote.
- A voter standing just outside the city line (e.g. across the street in East Cleveland) is "outside the city" with no distance, so their vote is off site.
- `my_votes` answers for any ID it's given; the ID is the secret.

## Testing approach (Oct 22)

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
