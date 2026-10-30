# Public Land Voting Tool: proximity version

Owner: Tim (Planning and Design Specialist, Western Reserve Land Conservancy). This is a new build, separate from the coalition-maps tool (`timothydehm/public-land-vote` + Supabase `parcel-vote`), which stays as it is. The product name is still **Public Land Voting Tool**. Don't use "Ballot".

- Repo: `timothydehm/public-land-record`, GitHub Pages from `main` / root → https://timothydehm.github.io/public-land-record/
- Supabase project: `public-land-record` (ref `seqjjbvfeosqpmwmivkt`, us-east-1, free plan, org `timothydehm`).

## Where things stand (Oct 26, 2026)

- **Live now:** version 2 (Tim ran `schema.sql` and uploaded `index.html`): feet; where-cast tiers from distance plus the city's neighborhood and ward boundaries; nearest tier sets the color; "Show votes cast" filter; Share the map; Download the data. The record has Tim's test votes (27 events on Oct 22).
- **Built and tested, not live:** version 3 (built Oct 26; see "Version 3" below) and timing without cutoffs (Tim, Oct 22: "I don't like arbitrary measurements"). The rapid/steady/unhurried labels (`vote_pace`, 10 s / 2 min cutoffs) are gone. Each vote keeps its raw `seconds_since_prev`; the card shows a lot's median compared with every vote in the record ("longer than 70% of votes"); the CSVs publish each vote's seconds and the comparison. No new measurement was added (Tim declined a "time on the lot" measure).
- **Version 3** (what each vote collects, group codes, location help) ships together with the timing change, in the same two files.
- **To go live (timing + version 3, together):** (1) run the whole `schema.sql` in the Supabase SQL editor once (rerunnable; adds the `groups` table and eleven nullable `vote_events` columns; drops the `current_votes` view's `pace` column, `vote_pace()`, the old one-argument `lot_tally_rows` / `lot_tallies` and the old seven-argument `cast_vote`, and recreates them). (2) Upload the new `index.html` right after; the new tally shape breaks the version 2 page. Claude can't apply drops through the Supabase connector without an approval, which times out unattended.
- **Printed cards:** `tools/make_cards.py`, run locally with the project's secret key. Unchanged.
- **Oct 30:** GitHub `main` had the version 3 page (`PAGE_VERSION = "2026-10-26"`) as of Oct 28. The screen work below was built on it and tested; page only, no schema change. To go live: upload the new `index.html`.

## Purpose and principle

A public, parcel-keyed record of what people want for city-owned vacant land, built to hold decision-makers accountable. It's meant to pair with community engagement, not replace it.

**No gates, just evidence.** Anyone can vote on any lot. No codes, sign-ups, or budgets. Each vote records how it was cast (distance from the parcel, whether it was cast inside the lot's neighborhood and ward, timing), and display rules decide how much it counts. Only raw measurements are stored; no threshold is written into stored data. Every threshold lives in a function argument or a view and can change without touching the record. The rules are public ("How votes count" page).

Removed from the previous tool, on purpose, and staying removed: coalition maps, map leaders and leader codes, invite codes and organizer keys, vote budgets, map deletion, share-with-decision-makers and its sent log. Generated group codes (version 3) now let a group gather its votes without changing counts.

## Version 3: what each vote collects, group codes, location help

Status: built and tested Oct 26, not live. Ship it together with the timing change that's built but not live: one `schema.sql` run in the SQL editor, then the `index.html` upload right after. The new tally shape breaks the version 2 page.

### Principles

- Record only what's lost if it isn't captured at the cast. Everything else (vote order, step distance, neighbor matches, patch score, variety, pace, coverage, voter-level measures) is computed later from the record.
- No thresholds, labels, location or identity in stored data.
- Group codes are for organizing, not evidence. They never change counts, colors or precedence.

### 1. New columns on `vote_events`

All nullable; earlier rows stay blank. The append-only trigger is unchanged.

- `speed_ms` (real): the browser's `coords.speed` when it's not null, otherwise computed on the device from the last two fixes. Null with no fix. Capped to fit the column.
- `speed_source`: `gps` or `fixes`.
- `saw_everyone` (boolean): the everyone's-votes view was on.
- `filter_at_cast`: the tier filter (`lot`…`city`, `all`). Invalid values are stored as null.
- `group_filter_at_cast`: the group code in the Show votes cast filter, or null.
- `opened_record` (boolean): "City record" was expanded on this lot's card before the vote.
- `touch_device` (boolean): `matchMedia('(pointer: coarse)')`.
- `arrived_via`: `card_link` if this page load had `?card=`, otherwise `direct`. Printed cards are derived later from `cards`.
- `page_version`: the page's `PAGE_VERSION` constant, length-capped.
- `group_code`: the device's group when the vote was cast, or null.
- `location_status`: `ok`, `declined`, `denied`, `unavailable`, `timeout`, `unsupported` or `waiting`.

### 2. Database

**Groups**

- `groups` table (`code` primary key, `created_at`), with RLS and no policies.
- `create_group()` (anon) returns a new unused code in the form `MAPLE-RIVER-42`: two words from fixed lists of short, common, inoffensive words, and a number from 10 to 99.
  - The lists live in the function and must be large enough that codes can't be guessed by trying them in bulk.
  - There are no names, owners, keys or limits.
- `group_exists(code)` (anon) returns true or false.
- Codes are normalized the same way in the page and the database (trimmed, uppercased, spaces turned into hyphens); the database decides.

**`cast_vote`**

- Takes all the new fields as optional arguments. Drop and recreate it, since the signature changes.
- If coordinates are present, `location_status` is `ok` whatever the page sent.
- Errors write nothing: `bad_group` for an unknown code, `bad_location_status` for an invalid status. Enum values are validated and lengths capped. Nothing raises with coordinates.
- A vote's group is the one on its latest cast, the same rule as tier. Re-casting without a code removes the vote from the group, and with one adds it.

**Views and functions**

- `current_votes` gains `group_code`.
- `lot_tally_rows` / `lot_tallies(farthest, group_code default null)` use the timing change's shape. A null group means no group filter. Nearest-tier precedence and grey ties apply within the filtered votes.
- `export_group_lots(code)` and `export_group_votes(code)` (anon) produce the same two CSVs filtered to one group. They refuse unknown codes.
- `votes_flagged` includes `group_code`.

### 3. Page

**On load, in this order**

1. Read `?card` and `?group`.
2. Set `arrived_via`.
3. Adopt the card through the existing flow, including the prompt when the device already has votes under a different ID.
4. Check the group with `group_exists`, adopt it, and confirm with "Group MAPLE-RIVER-42 on." A bad link is refused with a message.
5. Strip both parameters from the address bar.

**Location**

- Keep the latest `watchPosition` state. An earlier fix is used when one exists.
- Keep the last two fixes in memory only, for the speed fallback.
- The tier doesn't change: any vote without a fix stays in "no location."

**Tracking**

- `opened_record` resets when another lot is selected.

**Groups on the page**

- More > Group: Start a group generates a code, turns it on for this device, and shows it large with Copy link, a QR code and Share. The link is `…/?group=<code>`. One line on the screen: "Anyone with this code can join the group and see its votes."
- More > Group: Join a group is a field for typing a code. An unknown code shows "No group with that code."
- While a code is on, a bottom-bar chip shows "Group: MAPLE-RIVER-42 ×", and × turns it off. The code is stored in `plvt:group` and belongs to the device, not the voter ID.
- Show votes cast gains a Group field: exact match, checked against `groups`, combined with the tier chips. There's no list of codes anywhere. It applies to the your-votes view as well.

**Card's "Your vote" line**

- Order: "Your vote: Development · 340 ft away, on the block · MAPLE-RIVER-42".
- With no fix: "… · no location · MAPLE-RIVER-42 · Why?".

**The Why? sheet**

It opens only when tapped, or from More > Use my location after a failed attempt. The message depends on the status:

- unavailable: "Your device couldn't find its location. On a laptop, location is often turned off for the browser in the computer's settings." Followed by the path for the detected system:
  - macOS: System Settings > Privacy & Security > Location Services, then turn on your browser.
  - Windows: Settings > Privacy & security > Location.
  - Otherwise, generic text.
- denied: "Location is blocked for this site. You can allow it in your browser's site settings." Plus the macOS line for Safari, which reports system-level location off as denied.
- timeout: "Finding your location is taking a while."
- unsupported: "This browser can't share location."
- declined: "You chose not to share location." Includes a Use my location button.

Every version except unsupported has Try again, which restarts `watchPosition`. When a fix arrives, the sheet says so and tells the voter to re-cast to update the vote. It never re-casts automatically.

The sheet also shows a QR code with "Scan with your phone to vote there with your location. Your votes come with you." The QR holds `…/?card=<id>`, plus `&group=<code>` when a group is on. Under it goes the line "Anyone with it can vote as you."

**Every cast**

- Send all the fields with every `cast_vote`, clears included. A `bad_group` response reverts the vote with a message.

### 4. Exports

**Every vote** (public) gains:

- `moving_speed_mph` (1 decimal)
- `everyone_votes_showing` (yes/no)
- `filter_at_cast`
- `city_record_opened` (yes/no)
- `location_status`

It never includes `group_code`, `group_filter_at_cast`, `touch_device` or `arrived_via`.

**Votes by lot** (public): unchanged.

**Group CSVs** (Download the data > Group code): the same columns and rules, filtered to that group's current votes. No IDs and no time of day.

### 5. How votes count page

Replace it with the text below. Don't add any claim about IP addresses: Supabase's request logs may keep them.

> **What happens when you vote**
>
> Anyone can vote on any lot. There's no sign-up and no limit. Instead of checking who you are, we record how each vote was cast. Then anyone looking at the results can see what kind of votes are behind them.
>
> **What we record with each vote**
>
> Your choice and the lot. How far you were from the lot, rounded, and whether you were in the lot's neighborhood and ward. We keep the distance, never where you were. Whether your device could find its location, or you chose not to share it. How fast you were moving. How long it had been since your previous vote. Whether you could see other people's votes when you voted. Whether you opened the city's record for the lot. Whether you used a phone or a computer, and whether you came from a printed card. Your group code, if you joined one. The date and time.
>
> **What we don't record**
>
> Your name, contact details, or location. Your votes are tied together by a random code saved on your device. Your voter card holds that code.
>
> **What we publish**
>
> Every vote, with how it was cast, so anyone can download the data. We leave out the code that ties a voter's votes together, the time of day, and group codes. Anyone with a group's code can download that group's votes the same way.
>
> **How votes count on the map**
>
> On every lot, the votes cast closest to it set its color. Votes without a location still count, but they come after every vote that has one. The record keeps whether a location was unavailable or turned down. Voting from a phone gives a location. Everything else is there to read, not to rank.
>
> **Groups**
>
> A group code helps a block club or coalition gather its votes and see them together. It doesn't change how any vote counts.
>
> **How others may use it**
>
> A city department, a council member, or a neighborhood group may decide some votes deserve more weight than others. For example, they might count only votes cast in the neighborhood, or leave out votes cast seconds apart. That's their choice, and anyone can check it against the same data. If someone tells you how people voted, ask them which votes they counted.

### 6. Tests

**Schema**

- Upgrade from the live schema and a fresh install.
- Invalid enum values: `filter_at_cast` is stored as null; an invalid `location_status` returns `bad_location_status`.
- `bad_group` writes nothing.
- Status is forced to `ok` when coordinates are present.
- Group membership follows the latest cast. The group filter combines with the tier filter, and precedence and ties apply within it.

**Groups**

- Codes are unique, normalization matches in the page and the database, and unknown codes are refused.
- The group link is adopted and stripped. The combined `?card&group` link runs the card prompt, then the group.
- The chip turns the group off.
- The group filter applies in the your-votes view.
- Group CSVs are filtered, with no IDs or group column. Public CSVs have no group column.

**Location**

- Each status reaches the right sheet text, including OS detection and the Safari denied case.
- Try again shows a fix and doesn't re-cast.
- The continue QR carries the card and group.

**Collection**

- Speed: GPS speed when present, the two-fix fallback when absent, null with no fix.
- `saw_everyone` and both filter fields match the screen.
- `opened_record` resets between lots.
- `arrived_via` is `card_link` only on the adopting load.

**Exports and requests**

- The vote file's new columns are present, and the excluded ones are absent.
- The How page text is in place.
- Every call is still a POST with nothing in the URL.

### Decided, for later

- Geometric neighbors: lots whose nearest-lot zones touch (Voronoi).
- Each voter counts equally in lot-level descriptions.
- The share link stays plain.
- Criteria and analysis come after collection. The lot file's voter columns are planned around: on the ground, pace, telling lots apart, patch score, independence, printed card, and `voters_with_other_votes`.

### Deferred

- Manual pin. Revisit if `unavailable` turns out to be common. If it's built, store `location_source = pin` and throw away the coordinates after computing the distance. Rank pinned votes either as their own tier above "no location" or in their distance tier, always hatched and below GPS votes.

### Open

- Where criteria would be set: the public map or a separate page.
- Confirm the three proposed resolutions above: `group_filter_at_cast`, continue-on-phone counted as `card_link`, and the group filter in the your-votes view. (Built as written.)
- Group codes can be found by bulk guessing. The format allows 1,063² × 90 ≈ 102 million codes; anyone calling `group_exists` a few hundred times a second would hit one of 100 existing groups in about an hour. Joining a found group lets someone add votes under it and download its votes (which are public anyway, without the group column). Options: a limit on failed lookups, or a longer code. Not built; Tim's call.

### Build notes (Oct 26): choices made where the spec was silent

- **Word list:** one list of 1,063 words used for both positions (more codes than two half-lists). Source: the EFF short wordlist, trimmed of anything that could read badly, brand names, politics, and words like "voter", plus nature and neighborhood words. Lives in `create_group()`.
- **`group_filter_at_cast`** is stored only if it names a real group; anything else is null (so it can't carry free text).
- **`location_status`:** `ok` sent without usable coordinates is stored as null. Votes from the version 2 page send no status (null).
- **Speed:** kept only when the vote has a location. Negative, NaN and infinite values are dropped; capped at 100,000 m/s. An unknown `speed_source` is stored as null and the speed kept.
- **`page_version`:** letters, digits, `.`, `-`, `_` only, 32 characters at most. The page's constant is `PAGE_VERSION = "2026-10-26"`.
- **Group filter** (Show votes cast > Group) isn't remembered between visits (the tier chips are). While it's on, the lot card says "Showing group X's votes only." and a lot without the group's votes says "No votes from this group".
- **City record folds when another lot is selected**, so `opened_record` means opened on this lot. Before, an open City record stayed open from lot to lot.
- **Why? sheet:** for declined, Use my location is the Try again. `waiting` (no fix yet) uses the timeout text. The lot card hides while the sheet is open and comes back when it closes. The found message: "Location found. To add it to a vote, re-cast the vote: tap your choice to clear it, then tap it again."
- **Denied clears the earlier fix** (as before), so a revoked permission is respected; other errors keep it.
- **The locate button** (top right) is unchanged: a toast when location is denied. Only the card's Why? and More > Use my location open the sheet. (Oct 30: locate is in the top bar and opens the Why? sheet itself.)
- **Group page** is a hash route, `#/group` (More > Group): the device's group large with QR, Copy link and Share; Start a group; Join a group.
- **The timing comparison** stays against the whole record when a group filter is on.
- **Every vote CSV:** the five new columns come after `date`, so the earlier columns keep their places.

## Screen (Oct 28–30): top bar, tray, card chart, onboarding

Page only (`PAGE_VERSION = "2026-10-30"`); nothing stored changes meaning. Tim, Oct 28–30: simplify; no always-visible key or legend, no hints in the bottom bar; one tray for voting with Everyone / Mine beside the choices; no map filter for where votes were cast (solid and hatched already show it); tools as icons in a top bar like Felt Maps, no labels on the bar (people can explore; the welcome names them once); the card's votes as a picture (Card 1, closest on the left). Mockups: the design canvas "Public Land Voting Tool: bar and card mockups".

- **Top bar:** every tool as one icon. Phones: search, group, share, voter card, download, how votes count, locate. Search opens a field across the bar (× or Esc closes it; choosing a result opens the lot and returns the bar to icons). Wide screens: the name on the left, group, share, voter card, download and how votes count in the middle, a search field and locate on the right. Locate starts location, centers on you, or opens the Why? sheet when location isn't working.
- **Cards, not pages** (Tim, Oct 30: "pop down a little menu or card so that the map is still kind of visible"): Group, Share, Your voter card, Download the data and How votes count each open a card under the top bar; the icon shows pressed while it's open. Phones: across the screen, at most 60% of its height, so map shows above the tray; wide screens: 400 px wide, hanging under its icon. A tap on the map (or a lot, which then opens), Esc, ×, or the same icon folds it away; another icon swaps it. Each still has its `#/` link (`#/group`, `#/share`, `#/card`, `#/data`, `#/how`). Download the data: the two files as rows that download at once, then "A group's votes" (code field, filled in with this device's group, and both files), then "What's in the files" folded. Share the map: the plain link, Copy link, and Share where the phone has a share sheet ("Your votes don't come with it").
- **Tray:** the three choices and a stacked Everyone / Mine toggle. More, the key and the Show votes cast filter are gone. `filter_at_cast` is always `all` from this version; a filter saved by an earlier version is ignored.
- **Lot card:** address; "Parcel 105-12-001 · Hough · Ward 7"; the headline result ("Open space · 2 of 3 votes cast at the lot", "Tied · 4 votes cast on the block", "No votes yet"); the chart; the timing line ("Timing: median 14 s after the voter's previous vote · longer than 85% of votes"); one line about you (where you are until you vote on the lot, then your vote with the distance it was cast from); City record.
- **The chart:** a line per choice with its total, a dot per vote, in seven columns from the lot (left) to no location (right): at the lot, on the block, in the neighborhood, in the ward, elsewhere in Cleveland, outside Cleveland, no location. Under the columns: "at the lot · farther → · no location". No-location votes are hollow dots. More than three votes in one place show as a number in the choice's color. The shaded column is the one that sets the lot's color (the nearest with votes). Hovering a mark says what it is; screen readers get a sentence ("Open space: 2 at the lot, 1 on the block").
- **First visit:** one sheet above the tray: the name, one line on what it is, "Tap a lot, then pick a choice below. Tap it again to clear it.", the seven tools named once with their icons, and the location question (Use my location / Not now; Start when location is already allowed, blocked or unsupported), plus How votes count. Shown once (`plvt:welcomed`). Anyone who has votes or has answered the location note before counts as having seen it.
- **Save your card:** after the first vote that saves, a note under the top bar: "Your vote is saved on this device. Save your voter card to see or change your votes on another device." Once per device (`plvt:card-nudge`); never for someone who came with a card link or has opened Your voter card; never blocks voting.
- **Your voter card:** Copy link and Save image (a PNG of the QR, the link and "Anyone with it can vote as you."; the share sheet on phones, a download on computers).
- **Search:** addresses and parcel numbers, matched in the page against the lots already loaded; nothing sent. "east 79th street" matches "E 79th St"; "105-12-0" lists parcels by prefix.
- **Groups:** the group filter is on the Group page ("See a group's votes", filled in with this device's group). While a group is shown, "Showing only MAPLE-RIVER-42 ×" sits above the tray next to the device's own "Group: … ×".
- **Later, maybe:** a short walkthrough of the tools (Tim, Oct 30: maybe too much for now); timing off the card once the analytics pane exists.

## The map (index.html)

One file, plain HTML/CSS/JS. MapLibre GL 4.7.1 from jsdelivr; qrcode-generator 1.4.4 from cdnjs (loaded only for the voter card). No supabase-js: the page calls the ten RPCs with `fetch` POST (`rpc()`), so coordinates are always in a request body, never in a URL.

- **Copied from the previous tool:** the lot loading (`loadParcels`, `buildParcels`, labels for lots without addresses, IndexedDB cache keyed by the city's edit date), the map setup (white paper + Esri imagery at 0.5 opacity, desaturated; OpenFreeMap positron street names on top; white lot outlines; dots below zoom 15; pink selection outline), the parcel card's city fields (every field the layer publishes, aliases as labels, blanks shown as "Blank", folded under "City record"), and the colors (open space `#00875F`, development `#0068A6`, yard expansion `#E6A200`).
- **Three fixed choices** (`CHOICES`): `open_space`, `development`, `yard_expansion`. Keys are stored; labels can change.
- **Where a vote was cast (tiers, nearest first)** (Tim, Oct 22): at the lot (≤200 ft, "on site"), on the block (≤500 ft), in the lot's neighborhood (city SPA boundaries), in the lot's ward, elsewhere in Cleveland, outside Cleveland, no location. Computed by `vote_tier()` in the database from the stored distance and two yes/no answers; `TIERS` in the page has the labels ("In Hough", "In Ward 7").
- **Display precedence** (Tim, Oct 22: nearest tier decides; replaces on-site vs off-site): on each lot, the nearest tier that has votes sets the color by its leading choice. Solid if that tier is "at the lot", hatched otherwise, plain with no votes. **Ties are grey** (`TIE`, `#8A8781`) (Tim, Oct 22). Computed server-side in `lot_tally_rows`. Hatching is a MapLibre `fill-pattern` (`h-<key>` images drawn on a canvas in `hatchImage`). Zoomed out: filled dot = solid, ring = hatched.
- **Units:** feet and miles everywhere (Tim, Oct 22). `fmtDist`: "130 ft" under 1,000 ft, then "0.4 mi".
- **Voting:** tap a lot (zoom ≥ 15) for the compact card, then a choice square in the bottom bar. Tap the active choice to clear; another to change. One lot at a time, on purpose. Optimistic on screen; each tap is one `cast_vote` with the latest location fix; saves on one lot go out in order; a failed save reverts with a message. Keys 1/2/3 vote, Esc closes.
- **Card:** address label, parcel number, the lot's neighborhood · ward · planning region (`lot_info`), one row per tier that has votes ("At the lot: 3 open space, 1 yard expansion", "In Hough: 2 development"; the deciding tier bold, tiers outside the current filter dimmed), a Timing line ("median 14 s after the voter's previous vote · longer than 62% of votes"; one timed vote drops "median"; no comparison until the record has two timed votes; "each vote was the voter's first" when none are timed), and "Your vote: Development · 340 ft away, on the block" (or "at the lot", "no location", "from outside Cleveland", "saving…").
- **Bottom bar:** see "Screen (Oct 28–30)": the tray holds the three choices and Everyone / Mine; the tools are in the top bar.
- **More (until Oct 28–30; replaced by the top bar):** color/solid/hatched key; **Show votes cast** chips: At the lot / On the block / In the neighborhood / In the ward / In Cleveland / From anywhere (default; remembered per browser), with "Changes only what you see, not the votes. On every lot, the votes cast closest to it set its color." It re-asks `lot_tallies(farthest)` and repaints (Tim found the old meters slider unclear about whether it set what counts as close or just changed the view; the chips are a view filter only). Then Use my location (if not on), Share the map, Your voter card, Download the data, How votes count. A tap on the map folds More away.
- **Your votes view:** your current votes only, solid if cast at the lot, hatched otherwise; the filter applies.
- **Share the map** (Tim, Oct 22: keep it general): the plain page address (never a card link), through the phone's share sheet if there is one, otherwise copied ("Link to the map copied"). Routing to council members, CDCs and planners is for later; the lot's ward and planning region (with the region's planner in `places.attrs`) are already in the database for it.
- **Timing** (Tim, Oct 22: not travel; "is this person thinking about the decisions or just plugging away"; then "I don't like arbitrary measurements… track the time between and that can be analyzed afterwards"): the measurement is `seconds_since_prev` (ms precision, since the voter's previous event on any lot). Its reference figure, like the lot and boundaries are for distance, is the record itself: the share of all current timed votes that came sooner (`median_pct` per lot, `seconds_pct` per vote in the export). No cutoffs, nothing stored; the comparison shifts as votes come in. First votes (no previous) are left out of the comparison. Doesn't change colors; no map filter. Implied travel speed is still stored and used only by `votes_flagged`. Known blur: for someone walking lot to lot the gap is mostly walking; Tim chose not to add a separate time-on-the-lot measure.
- **Download the data** (`#/data`, anyone): two CSVs, no voter IDs and no time of day (Tim, Oct 22). "Votes by lot": one row per lot with votes (parcel, address, neighborhood, ward, planning region, total, 21 counts `<tier>_<choice>`, votes_with_timing, median_seconds_since_voters_previous_vote, median_longer_than_pct_of_votes, closest tier, leading choice, map style). "Every vote": one row per current vote (parcel, address, neighborhood, ward, region, choice, cast_from, distance_ft, seconds_since_voters_previous_vote, longer_than_pct_of_votes, date), sorted by lot, not time. UTF-8 with BOM so Excel opens it cleanly.
- **Refresh:** tallies and your votes every 20 s while visible (`CONFIG.refreshSeconds`), skipped while a save is pending.
- **Pages** (hash routes over the map): `#/card` (Your voter card), `#/data` (Download the data, plus the Group code files), `#/how` (How votes count: Tim's version 3 text, word for word), `#/group` (Group).

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
- `cast_vote(voter_id, parcel_id, choice, lat, lng, accuracy_m, fix_age_s, speed_ms, speed_source, saw_everyone, filter_at_cast, group_filter_at_cast, opened_record, touch_device, arrived_via, page_version, group_code, location_status)` (version 3 fields as in "Version 3" above), `security definer`, PostGIS geography. Distance from the point to the lot polygon (0 inside), in feet, rounded (`round_distance_ft`): under 1,000 ft → nearest 10 ft; 1,000 ft–2 mi → nearest 100 ft; beyond → nearest half mile; outside the city boundary → `outside_city = true`, no distance, both yes/no false. Inside the city it also checks the point against the lot's neighborhood and ward polygons. Returns the vote's `tier`. Coordinates are discarded and never stored. The function sets `log_parameter_max_length_on_error = 0`; nothing in it raises with coordinates; the project's `log_min_duration_statement` is off. `seconds_since_prev` from the voter's previous event on any lot; `implied_speed_ms` = centroid-to-centroid distance between the two lots ÷ the exact elapsed time (capped to fit the column). A per-voter advisory lock keeps one voter's events in order. A clear with nothing to clear writes nothing. Errors come back as `{"error": "no_voter" | "bad_choice" | "bad_group" | "bad_location_status" | "parcel_not_found"}` and write nothing.
- `current_votes` (view): latest event per voter × lot, without clears, plus `tier`. A vote's tier is that of its *latest* cast, so a remote voter who later goes to the lot can clear and re-cast to make it on-site.
- `vote_tier(distance_ft, outside_city, in_neighborhood, in_ward)`, `tier_rank(tier)`: the rules, in one place each.
- `lot_tally_rows(farthest)` / `lot_tallies(farthest)` (public; one jsonb value, no row cap): per lot `[parcel, counts[21] (tier-major: lot, block, neighborhood, ward, city, outside, none × open space, development, yard expansion), [timed, median_seconds, median_pct], tier, lead, display]`. `median_pct` = share (0–100) of all current timed votes with a shorter `seconds_since_prev` than the lot's median (null until two timed votes exist). `lot_tally_rows` materializes `current_votes` once. `farthest` limits which tiers count toward the color (`lot`…`city`, or `all`); counts always include every tier.
- `my_votes(voter_id)`: `[[parcel, choice, distance_ft, outside_city, tier, group_code], …]`. No timestamps, so an ID never becomes a trail of movements.
- `lot_info(parcel_id)`: `{neighborhood, ward, region}`.
- `export_lots()`, `export_votes()`: the CSV data (no IDs, no time of day, no group codes; votes sorted by lot). Both wrap `export_lots_for(g)` / `export_votes_for(g)` (not public). `export_votes` rows have 16 values: the 11 before plus speed_mph, saw_everyone, filter_at_cast, opened_record, location_status.
- `groups`, `create_group()`, `group_exists(code)`, `export_group_lots(code)`, `export_group_votes(code)`; helpers `norm_group(c)`, `find_group(c)` (not public).
- `lot_tallies(farthest, group_code)` returns `{"error": "bad_group"}` for an unknown code and echoes the normalized `group_code`.
- `votes_flagged` (view, not public): one row per flagged event and reason: `implied_travel`, `burst`, `stale_fix`, `weak_fix`. Every threshold is in its `rules` CTE marked PLACEHOLDER (40 m/s, 30 events in 10 min, fix older than 300 s, accuracy worse than 150 m, at the lot = 200 ft). Flags are never stored; rewrite the view to change them. The map doesn't use flags yet.
- **Access:** RLS on every table, no policies; anon/authenticated can't read or write any table or view. They can execute only `cast_vote`, `lot_tallies`, `my_votes`, `lot_info`, `export_lots`, `export_votes`, `create_group`, `group_exists`, `export_group_lots`, `export_group_votes`. The Supabase security advisor lists these as public security-definer functions; that's intended.

## Printed cards (tools/make_cards.py)

Python 3.8+, standard library only. `python make_cards.py --count 40 --tag "Glenville block club, Nov"`. Asks for the secret key (or reads `SUPABASE_SECRET_KEY`), inserts N rows into `cards` with the tag, and writes `cards-<tag>-<date>.html`: a letter-size sheet, 3 across, dashed cut lines, a QR per card (`…/?card=<id>`) and one line of text. Open it in a browser and print. The tag isn't printed or put in the link, so it can't be forged.

## Known limits

- Location comes from the voter's browser; a determined person can fake coordinates. The record keeps accuracy, fix age and implied travel so `votes_flagged` can catch patterns, but nothing blocks a vote.
- Anyone can mint new IDs. That's by design: unlimited remote votes still can't override one closer vote.
- A voter standing just outside the city line (e.g. across the street in East Cleveland) is "outside Cleveland" with no distance.
- Neighborhoods and wards don't nest; a vote inside the lot's ward but outside its neighborhood is "in the ward". 3 lots have no neighborhood (gaps in the city's layer), so votes on them skip that tier.
- `my_votes` answers for any ID it's given; the ID is the secret.

## Testing approach

- Version 3 (Oct 26): local Postgres 16 + PostGIS 3.4 with Supabase-like roles and default grants; the live (version 2) schema with votes, upgraded with the new file and rerun, and a fresh install. SQL as `anon`, 62 checks on both: code format and uniqueness (200 codes), normalization, bad_group / bad_location_status write nothing (casts and clears), every field stored, invalid enums null, status forced to ok with coordinates, speed caps, group follows the latest cast, group filter with tier filter (precedence and grey ties within the group), exports (16 columns, no group codes or IDs, group files filtered, unknown codes refused), permission denials, votes_flagged group_code, append-only. Timing percentages rechecked (0/25/50/75). Playwright, 100 checks, with a fake geolocation that can fail with each error code and an OS/Safari override: start/join/chip/×, link adoption and stripping, `?card&group` order, group filter (map, tiers, your-votes view), every Why? text incl. Mac/Windows/other and Safari denied, Try again without re-cast, continue QR decoded (card + group), speed from GPS and from two fixes, screen state fields, opened_record reset, arrived_via on the adopting load only, touch_device, all three CSVs, How page text, every call POST with nothing in the URL and only the ten functions; plus earlier behavior (tap a lot, distance, keyboard, clear, failed save, timing line, Share, voter card QR, bad card link, desktop panel).

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
