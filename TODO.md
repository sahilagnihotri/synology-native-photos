# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

Last Updated: 2026-11-26 (review done: 71 findings, fix workers dispatched; Windows cross check passes)

## 2026-11-26: full-repo review, release build break, Windows core check

Dispatch state and owned paths are in `tasks.md`.

- [ ] BUILD-2: the same strip defect also leaves the release
  `libphotoscore.dylib` (the `cdylib` output) unloadable on macOS 27
  (`dlopen`: mis-aligned LINKEDIT string pool). Nothing loads it today (the app
  links the static `libphotoscore.a`), so it is only recorded here. If anything
  ever needs the dylib on macOS, set `strip = false` for the whole release
  profile and measure the app size change first.
- [ ] REV-2026-11: the six reviewers reported 71 findings against `1c2c107`.
  Reports with evidence, failure scenarios and suggested fixes are in
  `documentation/reviews/2026-11-26-full-repo-review/` (one file per area). A
  finding counts as CONFIRMED only once a fix worker has a test that fails
  without the fix. Dispatch state is in `tasks.md`. One line per finding:
  - [ ] R1-1 (high): HTTP redirects are followed cross-origin, resending the password, sid and SynoToken. [queued for worker FA]
  - [ ] R1-2 (high): Every GET path puts the session id (and for upload, SynoToken) into error text. [queued for worker FA]
  - [ ] R1-3 (high): Browse drops undecodable items, so the crawl stops early and the local index deletes the rest. [queued for worker FA]
  - [ ] R1-4 (medium): Session expiry (106, 107, 119) is indistinguishable from any other failure. [queued for worker FA]
  - [ ] R1-5 (medium): Recycle listing caps at 5000 files in walk order, before sorting by time. [queued for worker FA]
  - [ ] R1-6 (medium): File Station paging loops are unbounded. [queued for worker FA]
  - [ ] R1-7 (medium): download_original returns non-2xx bodies as the original file. [queued for worker FA]
  - [ ] R1-8 (medium): Upload treats a name-collision skip as success. [queued for worker FA]
  - [ ] R1-9 (medium): Recycle path guard accepts directories and some non-canonical paths. [queued for worker FA]
  - [ ] R1-10 (low): pin_version panics when a capability reports min > max. [queued for worker FA]
  - [ ] R1-11 (low): Restore and delete timeouts report "still in the recycle bin" whatever the real cause. [queued for worker FA]
  - [ ] R1-12 (low): Most mock tests do not assert the session or the parameters actually sent. [DEFER(R1-12): not scheduled in this pass]
  - [ ] R2-1 (high): delta reconcile fails outright for any library above 32,765 items. [queued for worker FB]
  - [ ] R2-2 (high): the "refuse delete when the recycle bin is off" rule lives only in the Swift UI, not the core. [queued for worker FC]
  - [ ] R2-3 (medium): a saved edit can be silently dropped: upload uses overwrite=false, which DSM treats as "skip". [DEFER(R2-3): not scheduled in this pass]
  - [ ] R2-4 (medium): an empty (or short) server listing wipes the whole local library. [queued for worker FB]
  - [ ] R2-5 (medium): restore_session reports Valid for an expired session (the probe never sends the sid). [queued for worker FC]
  - [ ] R2-6 (medium): delete during a crawl or Refresh deletes on the NAS, then reports failure. [queued for worker FC]
  - [ ] R2-7 (medium): every local read fails for the whole duration of a crawl or Refresh. [DEFER(R2-7): not scheduled in this pass]
  - [ ] R2-8 (medium): signing in to another account or NAS reuses the previous account's index and skips the crawl. [queued for worker FC]
  - [ ] R2-9 (medium): download_original and video playback hold the whole original in memory and re-download it every time. [DEFER(R2-9): not scheduled in this pass]
  - [ ] R2-10 (low): restore and empty lose the error kind or the count on a partial failure. [queued for worker FC]
  - [ ] R2-11 (low): Windows: atomic cache write fails when the target is open. [queued for worker FC]
  - [ ] R2-12 (low): temp file names can collide under concurrent thumbnail misses. [queued for worker FC]
  - [ ] R3-1 (high): reconcile and delete batches fail for any library above 32,766 assets. [queued for worker FB]
  - [ ] R3-2 (medium): grid ORDER BY defeats the index, every page sorts the whole space. [queued for worker FB]
  - [ ] R3-3 (medium): data-bearing migrations skip spaces whose crawl was still in progress. [queued for worker FB]
  - [ ] R3-4 (medium): reconcile sweep wipes the whole space when the listing ends early or empty (persistence half). [queued for worker FB]
  - [ ] R3-5 (low): hand-rolled transactions can strand an open transaction. [queued for worker FB]
  - [ ] R3-6 (low): a database from a newer app version is opened, accepted and its version mirror overwritten. [queued for worker FB]
  - [ ] R3-7 (low): histogram buckets are UTC and truncate toward zero. [queued for worker FB]
  - [ ] R3-8 (low): reconcile loads the entire library into memory. [DEFER(R3-8): not scheduled in this pass]
  - [ ] R3-9 (low): tests that cannot fail or pin the hazard. [DEFER(R3-9): not scheduled in this pass]
  - [ ] R4-1 (high): Sign-out does not clear the Keychain session when AppEnvironment.host was empty at launch, so the app silently signs back in. [queued for worker FS]
  - [ ] R4-2 (high): Detail viewer can show the previous photo's image for the current photo (late load overwrites newer state). [queued for worker FS]
  - [ ] R4-3 (medium): Unit tests still touch the real certificate pin store, and one deletes the pin of the user's real NAS host. [queued for worker FS]
  - [ ] R4-4 (medium): A video whose download is still running starts playing after the viewer was closed. [queued for worker FS]
  - [ ] R4-5 (medium): Recently Deleted restore or permanent delete that fails part way leaves a stale list, and the retry can never succeed. [queued for worker FS]
  - [ ] R4-6 (medium): Context menu "Delete Permanently" and "Restore" act on the whole existing selection plus the clicked item. [queued for worker FS]
  - [ ] R4-7 (medium): Downloaded originals stay in the system temp folder after sign-out and across launches. [DEFER(R4-7): not scheduled in this pass]
  - [ ] R4-8 (medium): Session expiry during use never routes back to login (`markExpired` has no callers). [DEFER(R4-8): not scheduled in this pass]
  - [ ] R4-9 (medium): Edited copy loses colour profile and metadata, and the decode path may upscale small originals. [DEFER(R4-9): not scheduled in this pass]
  - [ ] R4-10 (medium): Sign-out leaves the local asset index of the previous account on disk and in the running core. [DEFER(R4-10): not scheduled in this pass]
  - [ ] R4-11 (low): A failed Save in the photo editor shows nothing to the user. [queued for worker FS]
  - [ ] R4-12 (low): Edited filename has only HHmmss, and a partial save invites a duplicate. [queued for worker FS]
  - [ ] R4-13 (low): `OriginalImageCache` can delete or replace a file another task is about to decode. [DEFER(R4-13): not scheduled in this pass]
  - [ ] R5-1 (high): Returning to Library after a search, a drill-in or a Quick Filter leaves the data source on the old source, so "Library" shows search results, a co. [queued for worker FS]
  - [ ] R5-2 (high): A search, collection or server-side filter with a first page of 200 or more results shows the spinner forever, and page 2 can never load. [queued for worker FS]
  - [ ] R5-3 (high): No generation check in `loadWindow` or `schedulePageLoad`: a page fetched under an old snapshot of the data can land beside pages from a newer one,. [DEFER(R5-3): not scheduled in this pass]
  - [ ] R5-4 (medium): Duplicate date-section identifier `.day(0)` when the library holds a photo dated within a day of the Unix epoch and any photo with no date. [queued for worker FS]
  - [ ] R5-5 (medium): An active search overlays every other sidebar route, because the sidebar change handler never clears `activeSearch`. [queued for worker FS]
  - [ ] R5-6 (medium): `reload()` does not reset `totalCount` for live sources, so a delete from a search, collection or remote-filter grid leaves permanent blank cells. [queued for worker FS]
  - [ ] R5-7 (medium): The debounced search cannot be cancelled once the sleep ends, so clearing the box mid-search or typing again lets an older result win and can leave. [queued for worker FS]
  - [ ] R5-8 (medium): Cmd-Z undo restores by filename and by the recycle entry's "deletedAt", which is the file mtime, so it can restore a different photo than the one j. [DEFER(R5-8): not scheduled in this pass]
  - [ ] R5-9 (medium): Sign Out clears the Keychain under `env.host`, which is the host at launch and is empty after a first login, so the stored session survives Sign Out. [queued for worker FS]
  - [ ] R5-10 (medium): `prefetchItemsAt` calls `loadWindow` directly, bypassing the loaded-page and in-flight dedupe, so every prefetch tick refetches a page and rebuilds. [DEFER(R5-10): not scheduled in this pass]
  - [ ] R5-11 (medium): Delete resolves the selection by index against a data source that may already have switched under a still-visible old grid. [DEFER(R5-11): not scheduled in this pass]
  - [ ] R5-12 (low): Map annotations are validated only for non-nil, so (0,0), NaN and out-of-range coordinates reach MapKit. [queued for worker FS]
  - [ ] R5-13 (low): A failed count read replaces the library with "No photos", and a failed page read is invisible. [DEFER(R5-13): not scheduled in this pass]
  - [ ] R5-14 (low): The periodic and activation sync clears the user's selection and shifts the photo shown in an open detail viewer. [DEFER(R5-14): not scheduled in this pass]
  - [ ] R5-15 (low): Tests that do not test the delete wiring, and tests that encode the defects above. [DEFER(R5-15): not scheduled in this pass]
  - [ ] R6-1 (medium): dmg is named after the latest git tag, which can disagree with the app version and the code inside. [queued for worker FD]
  - [ ] R6-3 (low): 32 commit hashes in Fixed.md no longer exist. [queued for worker FD]
  - [ ] R6-5 (low): the core gate does not use `--locked` and has no minimum test count. [queued for worker FD]
  - [ ] R6-6 (low): test entry points fail open on a missing project or a mistyped flag. [queued for worker FD]
  - [ ] R6-7 (low): setup.sh installs software on anything other than `--verify` as the first argument. [queued for worker FD]
  - [ ] R6-8 (low): xcframework staleness ignores several inputs. [queued for worker FD]
  - [ ] R6-9 (low): declared dependencies that no source file uses. [queued for worker FD]
  - [ ] R6-10 (low): no advisory check, and the bundled SQLite is old. [DEFER(R6-10): not scheduled in this pass]
  - [ ] R6-11 (low): docs drift. [queued for worker FD]
- [ ] WIN-1 (partly done): `scripts/windows/check-core.sh` now runs for real
  and passes (see `Fixed.md`). Still open: `scripts/ci/ci.ps1` and
  `scripts/windows/setup.ps1` have never been EXECUTED. `setup.ps1` was fixed by
  reading only (`7705f48`). PowerShell 7.7.0 for macOS is unpacked at
  `~/.cache/claude-sandbox/pwsh/pwsh`, but running it from the agent session was
  refused by the permission classifier. To exercise them on the Mac:
  `~/.cache/claude-sandbox/pwsh/pwsh -NoProfile -File scripts/ci/ci.ps1 core` and
  `... -File scripts/windows/setup.ps1 -Verify` (the MSVC check is expected to
  fail off Windows). Tests have also never RUN on Windows: the cross check type
  checks and lints, it does not link or execute.
- [ ] WIN-2: the winget branch of `scripts/windows/setup.ps1` that installs the
  Visual Studio Build Tools has never run. Exercise it on a Windows machine
  without Visual Studio.
- [ ] WIN-3: the cross check prerequisites live only in the agent sandbox cache
  on this Mac (`~/.cache/claude-sandbox`: a second rustup home with the
  `x86_64-pc-windows-msvc` rust-std, and cargo-xwin 0.24.2 rebuilt to verify TLS
  against the bundled Mozilla roots because the macOS trust service is not
  reachable from the sandbox). For a normal terminal run:
  `rustup target add x86_64-pc-windows-msvc` and
  `cargo install --locked cargo-xwin`. Homebrew `llvm` was installed system
  wide on 2026-11-26; the check also passed without it on PATH.
- [ ] HOUSEKEEPING-1: this Mac's checkout had sat 57 commits behind
  `origin/main` since 2026-07-26. Leftovers of the old layout are still on disk
  and untracked: `app/`, `PhotosCore.xcframework/`, `dist/` (holds
  `MySynologyPhotos-1.0.1.dmg`). Delete them by hand once nothing in them is
  wanted.

## 2026-10-16: after the platform layout restructure

Layout is now `core/`, `platforms/macos`, `platforms/windows`, `build/`, `scripts/{shared,macos,windows,ci}`.
`scripts/ci/ci.sh all` is the local gate (measured PASS: Rust 385/0/1, Swift 498/0/0).
Windows work continues on the Windows machine from `documentation/platforms/windows-handover.md`.

- [ ] `.github/workflows/ci.yml` (manual, `stable` only) is untested; the Xcode on `macos-latest` may be older than the macOS 26 deployment target. Creating `stable` is Sahil's call.
- [ ] The `ci.sh` swift stage FAIL path was not falsified (fmt, clippy, test and unknown stage were, via `scripts/tests/test-ci.sh`).
- [ ] The Recently Deleted restore loop's "restored N of M" message has no test (loop reworked to `enumerate` in `375c156`).

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

- [ ] Restore gives the photo a NEW Synology Photos id (measured 2026-10-16: 73610 came back as 74368). Anything keyed on the old id (album membership, favorite, rating, tags, people) is probably lost on restore, and the local index must treat the restored file as a new asset. Check what survives, and warn in the Recently Deleted UI if metadata is lost.
- [ ] Albums (browse, create, add/remove); replace the sidebar Albums placeholder.
- [ ] The old trash-album flow left a "Recently Deleted" album on the NAS. Nothing in the app reads or removes it any more. Delete it by hand in Synology Photos if unwanted (the app never touches it).
- [ ] Albums next steps: the `synology-api` calls exist (`create_album`, `add_items`, `remove_items`, `list_album_items`, see `Fixed.md`); still to do are the `PhotosCore` FFI methods, the Mac Albums UI replacing the sidebar placeholder, and drag to album. The NAS account has ZERO albums, so the item list of a non empty album was never observed; the mock reuses the plain Item list element. Verify against a real album once Sahil approves creating a test album.
- [ ] Search filter facets (`SYNO.Foto.Search.Filter`): confirmed present and working (camera, geocoding, time buckets, folder_filter, etc.) but deferred this pass; plain keyword search shipped instead (see `Fixed.md`).
- [ ] Favoriting/naming mutations: read-only People/Places/Tags/Favorites browsing shipped (see `Fixed.md`); toggling a favorite, naming a person, and creating/editing tags are still not implemented (mutations, gated separately).
- [ ] Plan: `documentation/plans/2026-07-25-phase2-manage-implementation.md`.

## Phase 3+

- [ ] QuickConnect / DDNS remote access.
- [ ] Windows UI (core already designed to allow it).
