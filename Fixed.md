# Fixed — synology-native-photos

Completed work with commit hashes. Newest at top.

## Session 2026-07-26 (cont.): Map view, UX quick wins, map-cluster-into-grid

- **Map view.** New `Map` sidebar destination plotting located photos on an
  `MKMapView` with clustering (`globe.americas` glyph). Core exposes per-asset
  GPS: `Asset.latitude`/`longitude` parsed from Browse.Item `additional.gps`,
  schema v4 (`requires_recrawl`, so first launch re-crawls to populate coords),
  a `located_assets(space)` query + facade (`697dc01`); Swift test-double
  fallout `68d4f0b`. App map + sidebar + routing `71a7a91`. Re-verified against
  the real NAS: 165 items, 88 located, correct lat/lon at Browse.Item v2.
- **Map clusters open in the REAL grid.** Tapping a cluster/pin now routes those
  photos into the shared library grid via a new `WindowedDataSource.fixed`
  source (`73353ec`), so they inherit selection, real delete (recycle + undo),
  the full detail viewer (stills + inline video), and context menus, replacing
  the earlier lightweight sheet/`MapPhotoDetailView`. Back control returns to the
  pins; any sidebar row exits; deleting inside a cluster prunes the removed items
  in place (`DeleteController.lastDeletedIds`). `6d0e07f`.
- **Apple Photos UX quick wins** (`7acf512`/`d7c5d9b`/`494b017`/`fbbf0ce`/
  `2322c48`): circular People tiles; Subjects section hidden (dead on this NAS,
  case kept); native menu bar (Undo Delete / Select All / Delete / Zoom /
  Show-Hide Sidebar & Info) via `FocusedValues` + responder chain; right-click
  context menus on grid/viewer/recycle bin; header controls moved into a native
  window `.toolbar` with Sign Out relocated to an Account menu.
- **Date scrubber constraint spam** silenced: its 0x0-at-creation frame fought
  the label's required insets; made the trailing/bottom insets non-required
  (`99afb50`).
- Also fixed `scripts/test.sh` to find the Cargo workspace at the repo root
  (`42ad949`). Full app suite green throughout: 460 -> 463 tests, 48 suites.

## Session 2026-07-26: People + Geolocation Quick Filter

- The library Quick Filter now offers People and Geolocation facets alongside
  file type / date / rating. These are server-side `Browse.Item` clusters with
  no local-index column, so selecting one routes the grid through a live remote
  fetch (`filterItemsRemote`) rather than the local `filterAssets` path; the
  popover loads both cluster lists on open, disables the local-only file-type
  and rating controls while a person/place is chosen (they do not combine with
  the server query), and combines the date range on either route. Core query
  builder + facade `2e7f96c` (6 `filter_items_mock` tests pin the wire shape:
  person-only/geo-only omit unset params, all-set omits the unreliable `type`,
  envelope errors map through); app wiring `206f7d1` (4 new
  `WindowedDataSource` remote-filter tests). Favorites stays out: no server read
  filter and no local column on this NAS.
- Fixed `scripts/test.sh` to find the Cargo workspace at the repo root (it was
  looking for `core/Cargo.toml` and silently skipping the whole Rust suite),
  `42ad949`.
- Full suite green after the change: core workspace all passing (incl. the 6 new
  filter tests); app 446 tests in 46 suites, `** TEST SUCCEEDED **`.

## Session 2026-07-25 (cont.): media enrichment, viewer polish, real delete

- **Media model enrichment** (schema v3): Live Photo `.MOV` clips now classify as
  Video via the item `live_type` field (`69b6eba`), and each asset carries EXIF
  (camera/aperture/exposure/focal/iso/lens), description, rating, and video
  metadata pulled from Browse.Item `additional` (`75c96c2`, bindings `08932bd`).
- **Library-load fix:** the enriched `additional` is rejected by Browse.Item at
  version 1 (DSM error 120), so the crawl is pinned to version 2 and search keeps
  its own lean `additional` on version 1 (`d7766a5`). This was breaking the whole
  library load after enrichment.
- **Detail viewer polish:** real EXIF/rating/video metadata in the info panel
  (`f1cd6bd`), click-drag pan when zoomed (`b9c77be`), and a layout-warning fix
  plus real `.MOV` playback (`6f4f2bc`).
- **Real delete (design pivot).** The hybrid trash-album delete shipped first,
  then was replaced: it left photos in the Synology library (still visible in the
  web app), which is not what delete should mean. New model: everyday Delete is
  the real Foto delete (removes from the library everywhere, lands in the DSM
  recycle bin), recoverable via a File-Station-backed Recently Deleted. VERIFIED
  end to end against the real NAS: delete to `#recycle`, `FileStation.Thumb` works
  on recycle paths, `CopyMove` restore with `remove_src=true` plus a Foto reindex
  brings the photo back into the library. Core: `8dfc989`/`a7f4cea`/`64c3216`/
  `a72598f`. UI (real delete in the grid and full-photo view, RecycleItem-based
  Recently Deleted with thumbnails/restore/permanent-empty, and a Refresh):
  `6863836`/`5de5bb9`/`df1715b`/`6b8f418`/`ce5a4d6`/`81dfc82`. Cleanup done: the
  vestigial NAS "Recently Deleted" album was removed and the local `in_trash`
  flags cleared. Follow-up owed: delete the now-dead trash-album methods from the
  core. 347 app tests green; ~343 core tests green.

## Session 2026-07-25: detail viewer rework (Apple Photos parity)

Fixed the black box and reworked the detail viewer to Apple's full-pane model.
Plan: `documentation/plans/2026-07-25-detail-viewer-rework.md` (DONE).

- Root cause was NOT the inline video work: the library is all `photo`/`live`
  (zero `video` items), so everything took the QuickLook branch, which showed
  black because of a silent error catch plus a zero-framed `QLPreviewView`.
- Detail photos now render as a real `NSImage` with explicit loading and error
  (plus Retry) states, never a silent black frame (`3494aac`).
- Viewer moved out of the `.sheet` into the split-view detail pane, so the
  sidebar stays visible and it fills the pane; the grid stays mounted so back is
  instant (`2863284`).
- Toolbar with a Back chevron, a zoom slider bound to magnification, and the
  info toggle; Cmd+Up / Escape / Back return to the grid.
- Cmd+Down opens the selected photo into detail (`b944a99`).
- Verified: clean build, and the full unit suite green (296 tests) run
  independently. Visual confirmation by the user against the running build.

## Session 2026-07-25: About window + Synology API version documentation

- Native About window showing app version, build git SHA, Rust core version, and
  the key Synology API versions (`748c1ba`); build-time git SHA injected into a
  generated Swift source (`9bc9fa5`); `documentation/synology-api-versions.md`
  as the single source of truth for every API and its pinned version (`ee7c634`,
  DSM version filled in `3631ed9`). 4 new unit tests, suite green.

## Session 2026-07-25: delete-semantics + album-mutation probes

Empirical probes against the real NAS that unblock the delete/manage phase.
Verdict + shapes in `documentation/phase0-probe-results.md` and
`documentation/plans/2026-07-25-phase2-manage-implementation.md` section 0
(`0bcc256`).

- Proved end to end (on one authorized victim, backed up and fully restored)
  that `SYNO.Foto.Browse.Item delete` is a soft delete: it drops the item from
  the Photos index and moves the original to the home `#recycle`, but Synology
  Photos exposes no trash/restore API and `SYNO.Core.RecycleBin` is config only.
- Verified the album-mutation API reversibly: create (`NormalAlbum.create`),
  add (`add_item`), remove (`delete_item`), delete album (`Album.delete`).
- Confirmed File Station is available for recycle recovery, and that
  `FileStation.Upload` needs the SynoToken in the URL query.

## Session 2026-07-25: keyword search

Read-only toolbar search reusing the existing browse item decoder end to
end, verified against the real NAS. Brief: `.superpowers/sdd/feature-search-brief.md`.
Plan + probe transcript: `documentation/plans/done/2026-07-25-search.md`.
Report: `.superpowers/sdd/feature-search-report.md`.

- Core: `search()` in `synology-api` (`75da3eb`) calling `SYNO.Foto.Search.Search`
  with the confirmed real method `list_item` and param `keyword` (both `list`/
  `search` and `query` were tried and rejected by the real NAS). Reuses the
  existing `RawItem`/`Asset` decoder unchanged, since search results are flat
  and the same shape as `Browse.Item`. `search_assets` facade in photoscore
  (`c505c34`); bindings regenerated (`dcdedb0`).
- App: toolbar `.searchable` field, debounced 300ms, wired into
  `WindowedDataSource` as a third fetch source alongside space and discovery
  collection (`3af55b7`). Empty query returns to whatever the sidebar was
  showing; a genuine no-match shows a clean "No Results" empty state.
- Confirmed against the real NAS: keyword "food" returned 2 real photos
  (IMG_1619.JPG, IMG_1570.JPG) through the full app path (`PhotosCore::
  restore_session` -> `search_assets`, no OTP needed via saved device token);
  a nonsense keyword returned a clean empty list.
- Deferred, logged rather than guessed at: `SYNO.Foto.Search.Filter` facets
  (camera, geocoding, time buckets, etc.) are confirmed present and working
  but not wired into the UI this pass; plain keyword search shipped instead.
- cargo test --workspace: 213 passed, 0 failed. Xcode: BUILD SUCCEEDED;
  unit tests 225 passed in 25 suites.

## Session 2026-07-25: discovery browse (People, Places, Subjects, Tags, Favorites)

Read-only sidebar destinations reusing the existing pipeline end to end,
verified against the real NAS. Brief: `.superpowers/sdd/feature-discovery-browse-brief.md`.
Plan + probe transcript: `documentation/plans/done/2026-07-25-discovery-browse.md`.
Report: `.superpowers/sdd/feature-discovery-browse-report.md`.

- App: sidebar gains People/Places/Subjects/Tags/Favorites under a new Discovery
  section; tile grids (cover + name/"Add Name" + item count) drill into the
  existing `PhotoGridController`/`WindowedDataSource`, which now windows either
  a space's local index or a live discovery-collection fetch (`85e84d2`
  through `9422f1f`).
- Core: `Person`/`Place`/`Subject`/`Tag` models, `discovery.rs` listers,
  `Browse.Item` collection filter (`person_id`/`geocoding_id`/`general_tag_id`
  bare int, `favorite=true`), photoscore facade
  (`fetch_people/places/subjects/tags`, `fetch_assets_for`).
- Confirmed against the real NAS: 4 people (all with covers), 22 places
  (11 in Norway/Oslo), 0 tags (none created yet), 4 subjects (Food, Nature,
  Animals, Transportation). `fetch_assets_for(Person(...))` returns real
  photos.
- Deferred, logged rather than guessed at: Subjects (Concept) has no working
  photo filter on this NAS (every candidate param/API tried was rejected or
  silently ignored); Timeline was not probed this pass.
- cargo test --workspace: 200 passed, 0 failed. Xcode: BUILD SUCCEEDED;
  unit tests 215 passed in 25 suites.

## Session 2026-07-24/25: real-NAS bring-up, fixes, hardening

- Test pollution of real UserDefaults diagnosed: test suite wrote fixture host/username into `.standard` because `LoginPreferencesStore.save()` used `.standard`. Real prefs cleared; injection fix tracked in TODO. (in progress)
- Crawl errors now surface in the UI with a Try Again button instead of an infinite "Importing..." spinner (`0a0b34c`). Closes the gap that hid the error-119 bug.
- Signing team applied project-wide so the test bundle loads; whole suite runs again (`dea8221`). The "remember-me test failure" was this team mismatch, not a logic bug.
- Sign with the Agnihotri AS Apple Developer team (`5W67TF3579`) + bundle identifiers moved to `se.agnihotri.synologyphotos.*` (`0137ded`). Stable signature ends the repeated keychain prompt.
- All commit authors rewritten to `Sahil Agnihotri <sahilagnihotri@ymail.com>` and force-pushed (verified zero content change).
- Repeated keychain prompt fixed: public cert-pin moved out of Keychain to Application Support with one-time migration; stable dev signing (`eeabc83`).
- Continuous idle grid thumbnail flicker fixed: guard duplicate `applySnapshot`, no-op re-configure of the same asset, nonisolated memory-cache peek (`9f0cd36`).
- Schema migration that adds a data-bearing column now resets the crawl barrier to force a backfill re-crawl; no more hand-clearing the DB (`f78e511`).
- Thumbnails/downloads now key on `unit_id` (from `additional.thumbnail.unit_id`), not the item id, which returned an HTML error page and blank thumbnails (`3630c70` + core in `c0fcbeb`). Verified real JPEG bytes end to end.
- Browse/thumbnail/download now send the `X-SYNO-TOKEN` header; fixes Synology error 119 that left the crawl empty (`8f6d973`). Verified crawl imports 151 photos.
- Empty-library state shows a clear "No Photos" placeholder instead of a blank void; space switch triggers a crawl (`bc48af8`).
- Leaf-certificate pinning via a custom rustls verifier (exact DER match) instead of add_root_certificate, which failed the handshake against the NAS leaf cert (`00b3f49`).
- Grid snapshot crash on login fixed: `diffable` made optional with a pending-snapshot catch-up (`d96686d`).
- Login hardening: host normalization, TOFU cert pin, device-token 2FA (skip OTP after first), no password in error messages, remember-me, show/hide password toggle (`7e6683e`, `965aa39`, `7cac4ef`, `3b7b41a`, `7249e6e`).
- Self-healing xcframework rebuild when Rust sources are newer than the built lib (`498ac16`), which had been serving stale binaries.
- CLAUDE.md documents real-NAS debugging: device-token OTP reuse + verified API gotchas (`10fdeac`).
- Apple Photos UI + keyboard design spec (`c0fcbeb`); Phase 2 plan + project regen (`f505790`).

## Milestone reached

Full read pipeline verified against the real NAS: login (2FA + device token) -> TLS leaf-pin over Tailscale -> crawl -> local index -> real thumbnails rendering in the grid -> QuickLook detail. 151 dummy photos import and display.

## Planning and setup (earlier)

- Design doc written, adversarially reviewed, approved (`df0e635`, `d478428`, `5777cc4`); feasibility research digested (`28d04ad`); rules + safety invariants in CLAUDE.md (`9831ef8`); setup + test scripts (`1379dd1`, `68dfa29`); Phase 0+1 plan + interface contract (`4cd187b`).
- Task 1 toolchain (`fb0eeb6`); Task 2 workspace + 5 crates (`b0458c3`); Task 3 probe doc (`93d194f`); Task 4 gitignore + Cargo.lock (`cfc9360`, `38fecb6`); Task 5 models + CoreError (`8a628e8`); Task 9/12 API.Info + cert probe (`54856ae`).
