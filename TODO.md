# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

## In progress

- [ ] Apple Photos-style UI + keyboard model: sidebar, zoomable grid, multi-select, and keyboard map (arrows/space/return/escape/cmd-A, delete routes to a safe-confirm affordance until Phase 2) shipped; see `.superpowers/sdd/fix-apple-photos-ui-report.md` for what landed. Still open: real delete wiring (Phase 2) and date-section headers (see Phase 3+ below). Brief: `.superpowers/sdd/fix-apple-photos-ui-brief.md`. Design spec: `documentation/design/2026-07-24-apple-photos-ui.md`.
- [ ] Polished viewer (shift-arrow select, zoom+pan, info panel, drag-to-Finder export) shipped; see `.superpowers/sdd/feature-polished-viewer-report.md`. Still open: camera/EXIF and per-asset location in the info panel (no cheap read-only API found; `Place`/Geocoding is a collection concept, not a field on `Asset`), and video drag-export/streaming verification against a real video asset (untested against the live NAS this pass).

## Viewer + browsing enhancements (feedback 2026-07-25)

Done this session (see `Fixed.md`): media enrichment, `.MOV`/live video playback,
richer info panel (EXIF/rating/description/video metadata), click-drag pan,
timeline date-section headers + date scrubber, and Quick Filter (file type / date
/ rating). Remaining:

- [ ] Edit (crop/rotate): IN PROGRESS. Non-destructive: uploads the edited copy as
  a NEW asset (FileStation.Upload + Foto reindex, both verified); original immutable.
- [ ] Share link: DEFERRED pending the exact API shape. Create is
  `SYNO.Foto.Sharing.Passphrase set_shared` with a `policy` param whose type is
  undocumented (a JSON object returns `{"reason":"type"}`); reads/updates key on a
  `passphrase`; `SYNO.Foto.PublicSharing get` is the unauthenticated public read.
  Next step: capture the real `set_shared` request from the Synology web app
  (devtools or browser automation), then build create/list/revoke against it.
- [ ] Timeline day bucketing is UTC (chosen for monotonicity with taken_at, which
  the lazy windowed sections require). Photos near local midnight can land on an
  adjacent day header. Switch to local-timezone day bucketing (still monotonic
  with a fixed offset) as a follow-up.
- [ ] Date scrubber drag-to-jump: read-only indicator shipped; add drag-to-jump
  (the prefix-sum geometry `GridDateSections`/`dayStart(forAbsolute:)` is in place).
- [ ] Favorites in the Quick Filter: NOT feasible on this NAS (no server read
  filter and no local `favorite` column). People + Geolocation landed (see
  `Fixed.md`). Revisit only if a future DSM exposes a favorite filter.
- [ ] Code hygiene: remove the now-dead trash-album methods from the core
  (`deleteToTrash`/`restoreFromTrash`/`fetchTrash`/`trashCount`/`reconcileTrash`/
  `ensureTrashAlbum` and the app-trash `permanentlyDelete`), superseded by real delete.

## Needs visual confirmation (feedback 2026-07-26)

- [ ] Map cluster grid scroll: fixed with `relayoutAfterRemount` (`b39f6aa`) but
  the root cause (grid scroll geometry stuck after the MKMapView teardown on the
  map->cluster transition) is a GUI-layout timing issue not reproducible without
  the running app. If it still cannot scroll, the alternative cause is the
  MKMapView lingering in the responder chain and eating scroll-wheel events;
  next step would be to confirm the map view is fully removed when the cluster
  grid shows (or force it), and/or add an NSViewController appearance hook that
  re-tiles the scroll view.

## Map view (DONE 2026-07-26)

Shipped (see `Fixed.md`): per-asset GPS in the core (schema v4, re-crawl),
`MKMapView` clustering Map destination, and tapping a cluster/pin opens those
photos in the REAL library grid (fixed data source) with full select/delete/
viewer/context-menu reuse. Remaining polish:
- [ ] Optional: thumbnails on map pins (currently marker pins); address/city
  labels on section headers and the info panel (`additional=["address"]`).

## UI/UX parity with Apple Photos (adversarial review 2026-07-26)

Full report: `documentation/reviews/2026-07-26-ux-adversarial-review.md`.
Prioritized below. The first quick-wins batch (menu bar, context menus, native
toolbar, circular People tiles, hidden Subjects; review #1-#5) shipped
2026-07-26, see `Fixed.md`. Remaining quick wins:

- [ ] Consolidate the two Filter buttons (Quick vs Search) into one; drop the
  non-functional Search facet browser (review #6).
- [ ] Unify grid selection visuals on the checkmark-circle badge already used in
  Recently Deleted (review #7).
- [ ] Grid cell + zoom-slider `accessibilityLabel`s for VoiceOver (review #8).

Medium:
- [ ] Detail filmstrip + trackpad swipe/scroll paging (review #11).
- [ ] Grid->detail zoom transition (matchedGeometry) instead of opacity fade
  (review #12).
- [ ] Grid pinch-to-zoom, scroll-to-now / jump-to-top, Home/End; scrubber
  drag-to-jump (review #13, overlaps the scrubber follow-up below).
- [ ] Section headers carry a location line + select-whole-section (pairs with
  Map/geocoding) (review #14).
- [ ] Appearance-adaptive info panel (or `.popover`) with a mini-map (review #16).
- [ ] Crop aspect presets + straighten dial + flip (review #17).
- [ ] Dynamic Type in the AppKit header/scrubber (review #18).
- [ ] Press-and-hold Live Photo playback; grid hover-scrub (review #15).
- [ ] Inline Favorite/rating and Share/export once the write API lands
  (review #9, #10, gated on mutations).

Bigger bets:
- [ ] Years / Months / Days / All Photos browsing with the pinch transition
  (review #19); aspect-ratio mosaic layout (review #20).
- [ ] Albums create/organize + drag-to-album (review #21; also Phase 2 below).
- [ ] Import/upload UI for migrating off iCloud (review #24).
- [ ] Duplicates detection (review #23); Memories/For You (review #22); People
  naming/merge, captions, batch adjust, slideshow (review #25).

## Performance (feedback 2026-07-26)

- [ ] Detail viewer is slow to open images/videos and slower than the old QuickLook. Cause: `DetailImageView` calls `downloadOriginal` on EVERY open (no download cache, does not consult the tiny FIFO TempFileCache first) and decodes with `NSImage(contentsOf:)` at FULL resolution (does not use `ImageDownsample` like the grid does), with no decoded-image RAM cache. Fix (next pass, after Edit; same Detail files): a keyed on-disk original cache (by `cache_key`, shared by photo + video so re-opens never re-download), a byte-cost-bounded `NSCache` of decoded images, downsampled decode for the initial display (reuse `ImageDownsample`, full-res on zoom), and progressive thumbnail-first display. Generous cache sizes (user has 128/64 GB RAM + NVMe).

## Distribution

- [ ] `make dmg` produces a working installer but the app is Apple-Development
  signed, not notarized, so other Macs need a right-click -> Open the first
  time. For real distribution: get a "Developer ID Application" cert, build the
  dmg with `CODE_SIGN_IDENTITY="Developer ID Application: ..."`, then notarize
  with `xcrun notarytool submit ... --wait` and `xcrun stapler staple` the dmg.
  The script already accepts the signing env overrides; only the notarytool
  step needs adding.

## Build infra

- [ ] Make the xcframework rebuild self-healing. The `ensure-xcframework` preBuildScript only builds `PhotosCore.xcframework` when it is MISSING, not when the Rust core changed, so after any core pass the app build fails with "cannot find uniffi_..._checksum" until `make xcframework` is run by hand. Fix the preBuildScript to rebuild when the core sources are newer than the packaged xcframework (compare mtimes, run `make xcframework`). Until fixed: run `make xcframework` after every core change before building the app.

## Security (before real use)

- [ ] Change the DSM password `xatkiW-pitkew-dizno7` (exposed in chat during debugging).
- [ ] Switch the app from the main DSM account to a dedicated least-privilege `photosclient` user (Photos-only). Main account used during dev only. Steps in `documentation/phase0-probe-results.md`.

## Empirical NAS probes

- [ ] Subjects (Concept) photo filter: no working `Browse.Item` filter param or dedicated item-list API was found for `SYNO.Foto.Browse.Concept` on this NAS (every candidate tried was rejected or silently ignored, see `documentation/plans/done/2026-07-25-discovery-browse.md`). Subject tiles currently list but do not drill into photos. Revisit if a future DSM update exposes one, or if a differently-shaped API (not a Browse.Item filter) turns up.
- [ ] Timeline (`SYNO.Foto.Browse.Timeline`) date-grouped browse: not probed in the discovery-browse pass (deferred per that brief's own "optional, defer if it complicates" clause).

## Phase 2: manage (own plan)

- [ ] IN PROGRESS: REAL delete (design pivot 2026-07-25). The hybrid trash-album delete was built, then superseded after the user saw it: an app-album delete leaves the photo in the Synology library (still shows in the web app), which is not what "delete" should mean. New model: everyday Delete = the real Foto delete (removes from the library everywhere, lands in the DSM recycle bin), recoverable via a File-Station-backed Recently Deleted. Core DONE + verified end to end against the real NAS (delete -> #recycle, FileStation.Thumb works on #recycle, CopyMove restore with remove_src + Foto reindex brings it back; commits 8dfc989/a7f4cea/64c3216/a72598f). Swift UI rework in progress: real delete in the grid AND the full-photo viewer, RecycleItem-based Recently Deleted (thumbnails/restore/permanent-empty), plus a Refresh so NAS-side changes reflect. Cleanup still owed: remove the now-superseded trash-album core methods; delete the vestigial NAS "Recently Deleted" album (id 4) the old design created; clear the local in_trash flag so IMG_1837 (never really deleted) un-hides.
- [ ] Albums (browse, create, add/remove); replace the sidebar Albums placeholder.
- [ ] Search filter facets (`SYNO.Foto.Search.Filter`): confirmed present and working (camera, geocoding, time buckets, folder_filter, etc.) but deferred this pass; plain keyword search shipped instead (see `Fixed.md`).
- [ ] Favoriting/naming mutations: read-only People/Places/Tags/Favorites browsing shipped (see `Fixed.md`); toggling a favorite, naming a person, and creating/editing tags are still not implemented (mutations, gated separately).
- [ ] Plan: `documentation/plans/2026-07-25-phase2-manage-implementation.md`.

## Phase 3+

- [ ] Non-destructive editing (upload edited copies as new assets; originals immutable).
- [ ] Grid date-section headers (if deferred by the UI overhaul).
- [ ] QuickConnect / DDNS remote access.
- [ ] Windows UI (core already designed to allow it).
