# Discovery browse: People, Places, Subjects, Tags, Favorites

Read-only sidebar destinations that reuse the existing pipeline (X-SYNO-TOKEN,
unit_id thumbnails, windowed paging, flicker-safe grid, selection/keyboard/detail).
Full spec: `.superpowers/sdd/feature-discovery-browse-brief.md`.

## Step 0: real-NAS probe (read only) -- DONE, findings below

Ran a throwaway `core/photoscore/examples/probe_discovery.rs` against the
real NAS (reusing the saved session's sid, no OTP needed), then deleted it
per the brief (never committed). Confirmed facts:

- `SYNO.Foto.Browse.Person` list (v1): `{cover, id, item_count, name, show}`.
  `cover` is a unit_id-like int (thumbnail id), `name` empty string for
  unnamed people, `show` a bool. Real data returned 4+ people.
- `SYNO.Foto.Browse.Geocoding` list (v1): `{country, country_id,
  first_level, id, item_count, name, second_level}`. Real data returned
  Norway/Oslo clusters (Sentrum, Grunerlokka, St. Hanshaugen, Frogner) as
  the brief predicted.
- `SYNO.Foto.Browse.GeneralTag` list (v1): empty list on this NAS (no tags
  created yet) -- decodes cleanly, `{list: []}`, no shape error.
- `SYNO.Foto.Browse.Concept` list (v1): `{display_threshold, id,
  item_count, name, sort_index, visibility}`. Real data returned Food,
  Nature, Animals, Transportation.
- `SYNO.Foto.Browse.Category`: does not exist on this NAS (error code 103,
  no such API). Concept is the only subjects source; Category is dropped
  entirely, not modeled.
- `SYNO.Foto.Favorite.Item` / `SYNO.Foto.Browse.Person.Item` /
  `SYNO.Foto.Browse.Concept.Item` / `SYNO.Foto.Browse.ConceptItem` /
  `SYNO.Foto.Search.Search`: none exist (error 102, no such API).

Browse.Item filter param names, confirmed by comparing result sets against
each other and against a bogus-param control (an unrecognized param is
silently ignored by DSM and returns the same default/favorite-biased set
every time, which is how the false positives below were caught):

- **`person_id`** (bare int, e.g. `person_id=12279`, NOT an array/bracket
  form, NOT quoted) genuinely filters -- confirmed distinct result sets per
  person id.
- **`geocoding_id`** (bare int) genuinely filters -- confirmed distinct
  result sets per place id. Array form (`[756]`) is rejected (error 120,
  reason "type").
- **`general_tag_id`** (bare int) is accepted/validated: a made-up id
  (999999) returned a clean empty list rather than being silently ignored
  (the control-param check distinguishes accepted-but-empty from
  ignored-and-defaulted). No real tag exists yet to confirm a non-empty
  filtered result, but the shape is consistent with person_id/geocoding_id.
- **`favorite=true`** genuinely filters Browse.Item directly to the user's
  favorited items -- no separate Favorite list API is needed or exists.
- **`concept_id`** is explicitly rejected by DSM ("concept_id is not
  supported", error 120). Alternate names tried (`subject_id`, `tag_id`,
  `category_id`) were all silently ignored (proven via the bogus-param
  control returning the identical result set), not real filters. No
  dedicated Concept item-list API exists either (error 102 on every
  candidate name tried). **Subjects (Concept) is deferred**: the list API
  ships (people can see named subjects and counts) but selecting a subject
  tile cannot yet show its photos on this NAS/DSM version. Logged rather
  than guessed at.
- Timeline (`Browse.Timeline`) was not probed this pass; deferred per the
  brief's own "optional, defer if it complicates" clause -- not started.

## Step 1: core models

`Person`, `Place`, `Subject`, `Tag` uniffi Records in `core/models/src/lib.rs`:
id, name, item_count, cover_unit_id: Option<i64> (Person also carries a
`show: bool` flag reflecting DSM's own "hide from People" toggle, decoded
tolerantly). Favorites/Timeline reuse `Asset` — no new model.

## Step 2: synology-api listers

New module `core/synology-api/src/discovery.rs`:
- `list_people`, `list_places`, `list_subjects`, `list_tags`, `list_favorites`
  (offset/limit, X-SYNO-TOKEN, tolerant per-item decode, same `decode_one`
  pattern as browse.rs).
- Extend `browse::list_items` (or add a sibling) to accept an optional
  collection filter query param + value, reusing the existing `RawItem`
  decoder.

Tests: mockito per lister (token header sent, tolerant decode, cover ->
unit_id), collection filter added to the item-list query.

## Step 3: photoscore facade

`fetch_people/places/subjects/tags` (local-network calls, not cached locally
like assets — no local index for these in this pass) and
`fetch_assets_for(collection, offset, limit)` where collection is a UniFFI
enum `DiscoveryCollection { Person(i64) | Place(i64) | Subject(i64) |
Tag(i64) | Favorites }`. Keeps the unit_id + token invariants used
everywhere else. Version-pins against probed capabilities the same way
`page_source_for` does.

## Step 4: bindings

`make bindings`, commit regenerated `bindings/*`.

## Step 5: app sidebar + tile grids

- Extend `SidebarItem`/`SidebarSections`/`SidebarSelectionRoute` with People,
  Places, Subjects, Tags, Favorites sections (additive; Library/Albums
  unchanged).
- New `DiscoveryTileGridController`-ish SwiftUI view (or reuse a simple
  `LazyVGrid` — tile counts are small, unlike the asset grid, so the
  NSCollectionView requirement does not apply here) showing cover thumbnail +
  name ("Add Name" placeholder, disabled, for unnamed people) + item_count.
  Selecting a tile pushes into the existing `PhotoGridController` /
  `WindowedDataSource` against `fetch_assets_for`.
- Favorites selects straight into the photo grid, no tile step.
- Generalize `WindowedDataSource` to fetch from either a `Space` (existing
  library behavior, unchanged) or a `DiscoveryCollection` — smallest change
  that preserves every existing call site.

## Step 6: verify

- `cargo test --workspace` green.
- `make bindings`; commit.
- `cd app && xcodegen generate && xcodebuild build ... -> BUILD SUCCEEDED`.
- `xcodebuild test ... -only-testing:SynologyPhotosTests` (never bare test).
- Real-NAS read-only verify example kept runnable, uncommitted.

## Constraints

Small commits, one per collection type where practical, each green. No dashes
in prose/comments. No AI mention. Do not push. Do not touch delete/edit/album
mutation or project.yml signing.
