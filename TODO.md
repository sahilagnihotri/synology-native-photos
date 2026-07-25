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

## Security (before real use)

- [ ] Change the DSM password `xatkiW-pitkew-dizno7` (exposed in chat during debugging).
- [ ] Switch the app from the main DSM account to a dedicated least-privilege `photosclient` user (Photos-only). Main account used during dev only. Steps in `documentation/phase0-probe-results.md`.

## Empirical NAS probes

- [ ] Subjects (Concept) photo filter: no working `Browse.Item` filter param or dedicated item-list API was found for `SYNO.Foto.Browse.Concept` on this NAS (every candidate tried was rejected or silently ignored, see `documentation/plans/done/2026-07-25-discovery-browse.md`). Subject tiles currently list but do not drill into photos. Revisit if a future DSM update exposes one, or if a differently-shaped API (not a Browse.Item filter) turns up.
- [ ] Timeline (`SYNO.Foto.Browse.Timeline`) date-grouped browse: not probed in the discovery-browse pass (deferred per that brief's own "optional, defer if it complicates" clause).

## Phase 2: manage (own plan)

- [ ] IN PROGRESS: Hybrid safe-delete. Probe + album-mutation API verified 2026-07-25, design approved by the user (hybrid): everyday Delete moves the photo into an app-owned hidden "Recently Deleted" album (reversible, never calls the raw verb); a gated Delete Permanently calls the raw Foto delete (which still lands in `#recycle`). Building now: Rust core (album_write + permanent delete + trash facade + fetch_assets exclusion) then Swift UI (delete confirm, Recently Deleted view, restore, wire the stubbed Delete key). Shapes in `documentation/plans/2026-07-25-phase2-manage-implementation.md` section 0.
- [ ] Albums (browse, create, add/remove); replace the sidebar Albums placeholder.
- [ ] Search filter facets (`SYNO.Foto.Search.Filter`): confirmed present and working (camera, geocoding, time buckets, folder_filter, etc.) but deferred this pass; plain keyword search shipped instead (see `Fixed.md`).
- [ ] Favoriting/naming mutations: read-only People/Places/Tags/Favorites browsing shipped (see `Fixed.md`); toggling a favorite, naming a person, and creating/editing tags are still not implemented (mutations, gated separately).
- [ ] Plan: `documentation/plans/2026-07-25-phase2-manage-implementation.md`.

## Phase 3+

- [ ] Non-destructive editing (upload edited copies as new assets; originals immutable).
- [ ] Grid date-section headers (if deferred by the UI overhaul).
- [ ] QuickConnect / DDNS remote access.
- [ ] Windows UI (core already designed to allow it).
