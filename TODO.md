# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

## In progress

- [ ] Apple Photos-style UI + keyboard model: sidebar, zoomable grid, multi-select, and keyboard map (arrows/space/return/escape/cmd-A, delete routes to a safe-confirm affordance until Phase 2) shipped; see `.superpowers/sdd/fix-apple-photos-ui-report.md` for what landed. Still open: real delete wiring (Phase 2) and date-section headers (see Phase 3+ below). Brief: `.superpowers/sdd/fix-apple-photos-ui-brief.md`. Design spec: `documentation/design/2026-07-24-apple-photos-ui.md`.
- [ ] Polished viewer (shift-arrow select, zoom+pan, info panel, drag-to-Finder export) shipped; see `.superpowers/sdd/feature-polished-viewer-report.md`. Still open: camera/EXIF and per-asset location in the info panel (no cheap read-only API found; `Place`/Geocoding is a collection concept, not a field on `Asset`), and video drag-export/streaming verification against a real video asset (untested against the live NAS this pass).

## Detail viewer (Apple Photos parity) — feedback 2026-07-25

- [ ] BUG: detail viewer shows a black box instead of the image preview (see screenshots). Likely a regression from the inline video playback work (commits ffed883/1893cc2/ac595d2). Diagnose and fix so photos render again.
- [ ] Redesign the detail viewer to Apple Photos style: fill the RIGHT PANE with the sidebar still visible, not a centered floating modal box.
- [ ] Add a back button and a zoom control (slider) to the detail view toolbar.
- [ ] Keyboard: Cmd+Down opens/enters the selected photo into detail; Cmd+Up goes back to the grid. (Keep existing Return/double-click open and Escape close.)

## Security (before real use)

- [ ] Change the DSM password `xatkiW-pitkew-dizno7` (exposed in chat during debugging).
- [ ] Switch the app from the main DSM account to a dedicated least-privilege `photosclient` user (Photos-only). Main account used during dev only. Steps in `documentation/phase0-probe-results.md`.

## Empirical NAS probes

- [ ] Subjects (Concept) photo filter: no working `Browse.Item` filter param or dedicated item-list API was found for `SYNO.Foto.Browse.Concept` on this NAS (every candidate tried was rejected or silently ignored, see `documentation/plans/done/2026-07-25-discovery-browse.md`). Subject tiles currently list but do not drill into photos. Revisit if a future DSM update exposes one, or if a differently-shaped API (not a Browse.Item filter) turns up.
- [ ] Timeline (`SYNO.Foto.Browse.Timeline`) date-grouped browse: not probed in the discovery-browse pass (deferred per that brief's own "optional, defer if it complicates" clause).

## Phase 2: manage (own plan)

- [ ] Safe-delete + confirm; wire the stubbed Delete keyboard action to it. Delete-semantics probe DONE (2026-07-25, see `documentation/phase0-probe-results.md`): the raw Foto delete is a soft delete (file moves to home `#recycle`) but Synology Photos exposes no trash/restore API, so the everyday delete will be an app-owned hidden trash album (never call the raw verb); permanent-delete is gated and separate. Design direction to be confirmed with the user before building; needs the album-mutation probe (create album + add/remove items) next.
- [ ] Albums (browse, create, add/remove); replace the sidebar Albums placeholder.
- [ ] Search filter facets (`SYNO.Foto.Search.Filter`): confirmed present and working (camera, geocoding, time buckets, folder_filter, etc.) but deferred this pass; plain keyword search shipped instead (see `Fixed.md`).
- [ ] Favoriting/naming mutations: read-only People/Places/Tags/Favorites browsing shipped (see `Fixed.md`); toggling a favorite, naming a person, and creating/editing tags are still not implemented (mutations, gated separately).
- [ ] Plan: `documentation/plans/2026-07-25-phase2-manage-implementation.md`.

## App polish

- [ ] Document every Synology Web API the app uses, with the version range the real NAS advertises and the version the app pins, in `documentation/synology-api-versions.md`, so a future DSM update is a one-file lookup to adjust.
- [ ] About panel in the app showing app version + build number, git commit SHA (injected at build), Rust core version, and the key Synology API versions in use.

## Phase 3+

- [ ] Non-destructive editing (upload edited copies as new assets; originals immutable).
- [ ] Grid date-section headers (if deferred by the UI overhaul).
- [ ] QuickConnect / DDNS remote access.
- [ ] Windows UI (core already designed to allow it).
