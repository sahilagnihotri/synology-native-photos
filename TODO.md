# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

Last Updated: 2026-11-26 (review fixes and the adversarial pass landed: Rust 452/0/1, Swift 518/0/0, Windows cross check passes)

## 2026-11-26: full-repo review, release build break, Windows core check

Dispatch state and owned paths are in `tasks.md`.

- [ ] BUILD-2: the same strip defect also leaves the release
  `libphotoscore.dylib` (the `cdylib` output) unloadable on macOS 27
  (`dlopen`: mis-aligned LINKEDIT string pool). Nothing loads it today (the app
  links the static `libphotoscore.a`), so it is only recorded here. If anything
  ever needs the dylib on macOS, set `strip = false` for the whole release
  profile and measure the app size change first.
- [ ] REV-2026-11 (open remainder): the review reported 72 findings against
  `1c2c107`. 51 are fixed, the code fixes each with a test that failed first
  (see `Fixed.md`).
  The 21 below were not fixed in this pass. Reports with evidence and suggested
  fixes: `documentation/reviews/2026-11-26-full-repo-review/` (finding IDs match).
  - [ ] R1-12 (low): Most mock tests do not assert the session or the parameters actually sent.
  - [ ] R2-3 (medium): a saved edit can be silently dropped: upload uses overwrite=false, which DSM treats as "skip". Partly done: a skipped upload is now an error (`7544243`) and the edited file name carries the date (`465d445`). Open: the skip reply shape (`data.blSkip`) is unverified on the real NAS, needs one measured upload.
  - [ ] R2-7 (medium): every local read fails for the whole duration of a crawl or Refresh.
  - [ ] R2-9 (medium): download_original and video playback hold the whole original in memory and re-download it every time.
  - [ ] R2-11 (low): Windows: atomic cache write fails when the target is open. Cannot be tested from the Mac. Do it with the Windows work.
  - [ ] R3-8 (low): reconcile loads the entire library into memory.
  - [ ] R3-9 (low): tests that cannot fail or pin the hazard.
  - [ ] R4-7 (medium): Downloaded originals stay in the system temp folder after sign-out and across launches.
  - [ ] R4-8 (medium): Session expiry during use never routes back to login (`markExpired` has no callers).
  - [ ] R4-9 (medium): Edited copy loses colour profile and metadata, and the decode path may upscale small originals.
  - [ ] R4-10 (medium): Sign-out leaves the local asset index of the previous account on disk and in the running core. Partly done: signing in as another account or NAS now clears the index (`5945810`, `0c3271c`). Open: Sign Out itself leaves the index on disk.
  - [ ] R4-13 (low): `OriginalImageCache` can delete or replace a file another task is about to decode.
  - [ ] R5-3 (high): No generation check in `loadWindow` or `schedulePageLoad`: a page fetched under an old snapshot of the data can land beside pages from a newer one,.
  - [ ] R5-8 (medium): Cmd-Z undo restores by filename and by the recycle entry's "deletedAt", which is the file mtime, so it can restore a different photo than the one j.
  - [ ] R5-10 (medium): `prefetchItemsAt` calls `loadWindow` directly, bypassing the loaded-page and in-flight dedupe, so every prefetch tick refetches a page and rebuilds.
  - [ ] R5-11 (medium): Delete resolves the selection by index against a data source that may already have switched under a still-visible old grid.
  - [ ] R5-13 (low): A failed count read replaces the library with "No photos", and a failed page read is invisible.
  - [ ] R5-14 (low): The periodic and activation sync clears the user's selection and shifts the photo shown in an open detail viewer.
  - [ ] R5-15 (low): Tests that do not test the delete wiring, and tests that encode the defects above.
  - [ ] R6-3 (low): 32 commit hashes in Fixed.md no longer exist. The list of 32 dead hashes is in `documentation/reviews/2026-11-26-full-repo-review/fixes/fd-scripts-docs.md`. They predate the author rewrite, and `Fixed.md` has no commit subjects to re-map them by.
  - [ ] R6-10 (low): no advisory check, and the bundled SQLite is old.
- [ ] REV-F1: session expiry (DSM codes 106, 107, 119) now surfaces as an auth
  error (`e942def`), but nothing signs in again with the saved device token, and
  the app never routes back to login (same root as R4-8).
- [ ] REV-F2: `map_error_code` also maps File Station codes 400 to 404 to
  `Auth` and `OtpRequired`. For File Station calls those numbers are file
  operation errors. Not changed.
- [ ] REV-F3: after `25fac1e` a live grid (search, collection, server filter)
  holds one spare trailing cell while more pages may follow. When the result
  count is an exact multiple of the page size the blank cell shows briefly and
  Select All counts it. Not seen in the running app. Alternative: an explicit
  unknown-total mode.
- [ ] REV-F4: with several stored hosts or users, `loadMostRecentAccount` can
  pick an arbitrary stored session (login does not clear the others). Single
  account assumed.
- [ ] REV-F5: a sync refused because its session belongs to the previous
  account (`07c86b4`) returns a storage error, and the app shows its generic
  storage message for it.
- [ ] REV-F6: `scripts/macos/setup.sh --verify` still runs `cargo run` for the
  bindgen bin, and `check_uniffi` passes when the bindgen source is missing.
  The `platforms/macos/project.yml` comment says `DEVELOPMENT_TEAM` is left
  unset while the next line sets it. `Fixed.md` records the old bundle ids
  `se.agnihotri.synologyphotos.*` (the project uses `se.agnihotri.mysynologyphotos`).
- [ ] REV-F7: none of the 15 Mac app fixes of 2026-11-26 has been exercised in
  the running app or against the real NAS, only through unit tests. The UI test
  target was not run. A switch of account or NAS, and the first launch after
  this update, now clear the local index and run a fresh crawl.
- [ ] REV-F8 (decision for Sahil): when the recycle bin status is Unknown (a
  non admin account cannot read the setting) a delete still goes ahead after
  the Mac app's "may be permanent" confirmation. The core refuses only
  Disabled (`8ab1b83`). Options: keep, refuse Unknown too (non admin accounts
  could then not delete), or add an explicit "confirmed permanent" flag to the
  FFI. Running assumption: keep.
- [ ] AV-2026-11: adversarial review of the core fixes, open items. Detail,
  locations and suggested tests are in
  `documentation/reviews/2026-11-26-full-repo-review/fixes/av-core-diff.md`.
  AV-1 is fixed (`61dbe05`); AV-2 is REV-F2 above. All below were found by reading,
  none reproduced by execution.
  - [ ] AV-3 (medium, touches delete): a Shared space delete checks the user
    home recycle bin setting, not the photo share's own. Shared space is off on
    this NAS (error 801), so it cannot be measured here.
  - [ ] AV-4 (medium): login binds the index after the network login. If a
    crawl holds the store, the OTP is already spent, the server session is left
    open and the user sees "store busy". `restore_session` fails the same way.
  - [ ] AV-5 (medium): the account identity includes the host, so moving between
    the LAN address and the Tailscale name clears the index and thumbnails and
    forces a full crawl each time. Fix: bind to a NAS id (serial or pinned
    certificate) plus the user.
  - [ ] AV-6 (medium to low, part of SYNC-1): the sweep confirmation needs two
    identical listings, so it never confirms while a phone keeps uploading, and
    a stable truncated listing is confirmed on the second Refresh.
  - [ ] AV-7 (low): `sign_out` does not clear queued local deletes or cached
    originals. A queued id can drop an unrelated row in the next account's
    index (local only, healed by a reconcile).
  - [ ] AV-8 (low): a local row removal that fails after a successful NAS delete
    reports the delete as failed.
  - [ ] AV-9 (low): crawl and reconcile loop forever if the server ignores
    `offset`.
  - [ ] AV-10 (low): a `taken_at` within a day of `i64::MIN` overflows the day
    arithmetic and the whole date histogram fails.
  - [ ] AV-11 (low): the `list_items` doc comment is stale after `ee27208`.
  - [ ] AV-12: a comma inside a JSON path array is unverified on the real NAS
    (restore and delete of a file under a folder such as "Paris, France"). A
    wrong split fails with a File Station error: a folder name ending in a
    comma is refused, so no piece after a comma can be an absolute path.
- [ ] SYNC-1 (decision for Sahil): since `05240b6` a reconcile never applies an
  EMPTY server listing as deletions, and applies a drop of more than 20 percent
  of a space with 100 or more rows only when the same listing comes back twice
  in a row. Consequence: a library emptied on purpose on the NAS keeps its rows
  in the local index. Options: keep it, apply an empty listing on the second
  identical one, or add a "rebuild local index" action in the app. Running
  assumption: keep it (the conservative choice).
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
`scripts/ci/ci.sh all` is the local gate (measured 2026-11-26: Rust 449/0/1, Swift 518/0/0).
Windows work continues on the Windows machine from `documentation/platforms/windows-handover.md`.

- [ ] `.github/workflows/ci.yml` (manual, `stable` only) is untested; the Xcode on `macos-latest` may be older than the macOS 26 deployment target. Creating `stable` is Sahil's call.

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
