# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

Last Updated: 2026-10-16

## In progress

- [ ] Polished viewer: video drag-export and streaming are untested against a real video asset on the live NAS. Per-asset location in the info panel is still open (`Place`/Geocoding is a collection concept, not a field on `Asset`).

## Viewer + browsing enhancements (feedback 2026-07-25)

Done this session (see `Fixed.md`): media enrichment, `.MOV`/live video playback,
richer info panel (EXIF/rating/description/video metadata), click-drag pan,
timeline date-section headers + date scrubber, and Quick Filter (file type / date
/ rating). Remaining:

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

## Distribution

- Installer builds two ways (both call the shared `dmg-from-app.sh`, see
  `Fixed.md`): CLI `make dmg`, or the Xcode `Installer` scheme (Build it).
- [ ] The app is Apple-Development signed, not notarized, so other Macs need a
  right-click -> Open the first time. For real distribution: get a "Developer ID
  Application" cert, build the dmg with `CODE_SIGN_IDENTITY="Developer ID
  Application: ..."`, then notarize with `xcrun notarytool submit ... --wait`
  and `xcrun stapler staple` the dmg. The scripts already accept the signing env
  overrides; only the notarytool step needs adding.

## Build infra

- [ ] Three `var store` never mutated warnings in `CacheSettingsStoreTests.swift` (test only).
- [ ] xcodegen and `xcresulttool` must run outside the agent sandbox (temp file writes); regenerating the project from a sandboxed worker fails.

## Security (before real use)

- [ ] HIGH: change the DSM password. It was exposed in chat and committed in plain text to this PUBLIC repo in `db2a439` (removed from the file 2026-10-16, still in git history). Rotating it is the only fix.
- [ ] Switch the app from the main DSM account to a dedicated least-privilege `photosclient` user (Photos-only). Main account used during dev only. Steps in `documentation/phase0-probe-results.md`.
- [ ] Tailscale host and IP appear in tracked files (`CLAUDE.md`, docs, tests). The repo is PUBLIC; low risk, consider placeholders.

## Empirical NAS probes

- [ ] Subjects (Concept) photo filter: no working `Browse.Item` filter param or dedicated item-list API was found for `SYNO.Foto.Browse.Concept` on this NAS (every candidate tried was rejected or silently ignored, see `documentation/plans/done/2026-07-25-discovery-browse.md`). Subject tiles currently list but do not drill into photos. Revisit if a future DSM update exposes one, or if a differently-shaped API (not a Browse.Item filter) turns up.
- [ ] Timeline (`SYNO.Foto.Browse.Timeline`) date-grouped browse: not probed in the discovery-browse pass (deferred per that brief's own "optional, defer if it complicates" clause).

## Phase 2: manage (own plan)

- [ ] HIGH: recycle bin enabled check before delete. Nothing verifies the DSM recycle bin is on for the homes share. If it is off, delete is permanent while the UI says it can be restored. Needs a real NAS probe (one fresh OTP) of `SYNO.Core.Share` / `SYNO.Core.RecycleBin` for the homes share recycle setting.
- [ ] Verify on the real NAS: File Station error 408 for a missing folder (assumed from the official guide in `recycle.rs` `FS_NO_SUCH_FILE`), and that restore and permanent delete completion polling behave as mocked.
- [ ] Albums (browse, create, add/remove); replace the sidebar Albums placeholder.
- [ ] The old trash-album flow left a "Recently Deleted" album on the NAS. Nothing in the app reads or removes it any more. Delete it by hand in Synology Photos if unwanted (the app never touches it).
- [ ] Albums write API: `create_album`, `add_items` and `remove_items` were removed from `synology-api` as unused in `86864c6`. The Albums item above needs them: recover from `86864c6^` (`core/synology-api/src/album_write.rs` and its mock tests). `delete_album` and `normal_album_api` remain.
- [ ] Search filter facets (`SYNO.Foto.Search.Filter`): confirmed present and working (camera, geocoding, time buckets, folder_filter, etc.) but deferred this pass; plain keyword search shipped instead (see `Fixed.md`).
- [ ] Favoriting/naming mutations: read-only People/Places/Tags/Favorites browsing shipped (see `Fixed.md`); toggling a favorite, naming a person, and creating/editing tags are still not implemented (mutations, gated separately).
- [ ] Plan: `documentation/plans/2026-07-25-phase2-manage-implementation.md`.

## Phase 3+

- [ ] QuickConnect / DDNS remote access.
- [ ] Windows UI (core already designed to allow it).
