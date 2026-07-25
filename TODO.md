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
- [ ] Fold People / Geolocation / Favorites into the Quick Filter (currently via
  sidebar collections only); needs per-item favorite plus a way to combine cluster
  facets with the local compound filter.
- [ ] Code hygiene: remove the now-dead trash-album methods from the core
  (`deleteToTrash`/`restoreFromTrash`/`fetchTrash`/`trashCount`/`reconcileTrash`/
  `ensureTrashAlbum` and the app-trash `permanentlyDelete`), superseded by real delete.

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
