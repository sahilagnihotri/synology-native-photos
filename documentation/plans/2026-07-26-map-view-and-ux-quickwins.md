# Map view + Apple Photos UX quick wins (2026-07-26)

Batch requested after the People/Geolocation filter landed and the adversarial
UX review came in (`documentation/reviews/2026-07-26-ux-adversarial-review.md`).
User wants the Apple Photos map ("makes it easier to see where more pics were
taken, then click and it shows those images") plus the cheap native-feel wins.

## Orchestration

Serialized (NOT concurrent) because three artifacts are single and shared:
the UniFFI bindings + `PhotosCore.xcframework`, the xcodegen `project.yml`, and
`RootView`/`SidebarItem`. Concurrent agents would clobber the bindings or the
project file, and two concurrent `xcodebuild`s contend on shared DerivedData.
Order: (1) Map core, (2) Map app, (3) UX quick wins. Each is built, tested, and
committed before the next starts.

## 1. Map core (full-stack Rust + bindings)

Expose per-asset GPS so the map has coordinates to plot. Verified feasible:
88/165 items carry `additional=["gps"]` as `{"latitude": f64, "longitude": f64}`.

- `core/models/src/lib.rs`: add `latitude: Option<f64>`, `longitude: Option<f64>`
  to `Asset` (flat, optional, neutral `None` default like the rest).
- `core/synology-api/src/browse.rs`: add `"gps"` to `ITEM_ADDITIONAL`; add a
  tolerant `Gps { latitude: Option<f64>, longitude: Option<f64> }` under
  `ItemAdditional`; populate the two new `Asset` fields in the build block.
  Leave `SEARCH_ADDITIONAL` alone (search stays v1). Mock test for the parse.
- `core/persistence`: schema step v4 `add_location_columns_if_missing`
  (`latitude`/`longitude` REAL, nullable), `requires_recrawl: true` (NAS-derived,
  same reasoning as the v3 metadata step); add both columns to `BASE_DDL`; extend
  `ASSET_SELECT_COLUMNS`, `row_to_asset`, and the upsert INSERT + ON CONFLICT SET
  + params (positional order is load-bearing). New query
  `located_assets(space) -> Vec<Asset>` returning rows with non-null lat/lon.
- `core/photoscore`: facade `located_assets(space)`; regenerate bindings;
  `make xcframework`.
- Verify against the real NAS via a throwaway example that the combined
  `additional` (exif+description+rating+video_meta+gps) still returns items at
  Browse.Item v2 and that lat/lon populate.

## 2. Map app (SwiftUI + MapKit)

- New `Map` sidebar destination (`SidebarItem`/`SidebarSelection`, routed in
  `RootView`).
- `MapView` (MapKit) plotting `located_assets` as annotations with built-in
  clustering (`MKClusterAnnotation`). Tap an annotation/cluster -> show those
  photos: reuse the existing grid by feeding a fixed asset set (a new
  `WindowedDataSource` source or a lightweight sheet grid), then the normal
  viewer.
- Scale note: `located_assets` returns full `Asset` rows; fine for this library
  (88), log a cap for very large located sets rather than silently truncating.

## 3. UX quick wins (app-only, no core)

From the review, cheap + high-signal:
1. Real menu bar (File/Edit/Image/View) surfacing existing grid/viewer shortcuts.
2. Right-click context menus (grid cells, viewer, recently-deleted).
3. Move the custom header `HStack` into a real window `.toolbar`; Sign Out into
   an account menu.
4. Circular People tiles (albums/places stay rounded rects).
5. Hide/gate the dead "Subjects" sidebar section.

Deferred to later batches (bigger bets): Years/Months/Days + mosaic, albums
create/organize, import UI, filmstrip, zoom transition, live-photo playback,
favorite/rating/share (need the write API).

## Safety

All read-only. No delete/edit/mutation paths touched. Standard invariants hold.
