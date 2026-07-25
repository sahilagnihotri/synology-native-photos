# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

## In progress

- [ ] Apple Photos-style UI + keyboard model: sidebar, zoomable grid, multi-select, and keyboard map (arrows/space/return/escape/cmd-A, delete routes to a safe-confirm affordance until Phase 2) shipped; see `.superpowers/sdd/fix-apple-photos-ui-report.md` for what landed. Still open: real delete wiring (Phase 2) and date-section headers (see Phase 3+ below). Brief: `.superpowers/sdd/fix-apple-photos-ui-brief.md`. Design spec: `documentation/design/2026-07-24-apple-photos-ui.md`.
- [ ] Polished viewer (shift-arrow select, zoom+pan, info panel, drag-to-Finder export) shipped; see `.superpowers/sdd/feature-polished-viewer-report.md`. Still open: camera/EXIF and per-asset location in the info panel (no cheap read-only API found; `Place`/Geocoding is a collection concept, not a field on `Asset`), and video drag-export/streaming verification against a real video asset (untested against the live NAS this pass).

## Viewer + browsing enhancements (feedback 2026-07-25)

Shared prerequisite: a core "media model enrichment" pass. Browse.Item `additional`
exposes `exif` (camera, aperture, exposure_time, focal_length, iso, lens),
`description`, `rating`, `tag`, `person`, and (for videos) `video_meta` (codec,
container, duration, framerate, resolution); items also carry `live_type`
("photo"/"video") alongside `type`. Capture these in the Asset model, browse
decoder, and local schema; that single pass unblocks the video fix, info panel,
and filters. Do this AFTER the hybrid delete core lands (both touch models/browse/schema).

- [ ] BUG: live-photo videos (`.MOV`, `type=live` `live_type=video`) open with "could not load as image" because they route to the image renderer. Fix: media kind should treat `live_type=="video"` and `type=="video"` as Video so they play via AVPlayer (video_meta confirms h264/mp4). Show the play badge on them in the grid too.
- [ ] Richer info panel to match Synology: camera/lens/aperture/ISO/exposure/focal length (EXIF), description, rating stars, tags, people, and for videos codec/duration/framerate/resolution. Data is in Browse.Item `additional`.
- [ ] Confirm pan works when zoomed in the detail viewer (scroll to pan once magnified); fix if not.
- [ ] Quick Filter (Synology parity): file type (photo/video), date taken (year/month), favorites, rating, plus people and geolocation. Local-first over the SQLite index (needs favorite/rating/media-type columns); people/geolocation reuse the existing discovery collections.
- [ ] Share link: create a public share link for a photo/video (`SYNO.Foto.PublicSharing` / `SYNO.Foto.Sharing.*`). New feature; probe read-first.
- [ ] Edit (crop/rotate): Phase 3 non-destructive (upload the edited copy as a NEW asset; original stays immutable).

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
