# Handover: synology-native-photos

Paste everything below the line into a fresh Claude Code session in this repo
(`/Users/sahil/code/github/synology-native-photos`). Nothing critical lives only in
chat: `CLAUDE.md` (rules), `TODO.md` (pending), `Fixed.md` (done, with hashes) and
`documentation/` hold the rest. Last refreshed 2026-10-16.

---

You are continuing work on **synology-native-photos**, a native macOS Apple Photos style client for a Synology NAS over its Web API. Rust core in `core/` (exposed to Swift via UniFFI), SwiftUI/AppKit app in `app/`. Read `CLAUDE.md` first; it is authoritative. Then read `TODO.md` and `Fixed.md`.

## Current state

Bundle id `se.agnihotri.mysynologyphotos`, display name "MySynology Photos". Unit test target `MySynologyPhotosTests`.

Shipped:
- Login (2FA plus device token), TLS leaf-cert pinning, crawl into a local SQLite index, fast NSCollectionView thumbnail grid with date-section headers and a date scrubber, zoom slider, multi-select and keyboard model, native menu bar, context menus, native toolbar.
- Detail viewer: zoom and pan, info panel with EXIF/rating/video metadata, arrow paging, inline video and Live Photo playback, drag-out export, two tier original cache with downsampled decode and thumbnail-first display.
- Browse: People, Places, Tags, Favorites (read only), Map view with clustering that opens clusters in the real grid, keyword search plus date range, Quick Filter (file type, date, rating, People, Geolocation).
- Real delete: the Foto delete moves the file to the DSM recycle bin. Delete from the grid, context menu, toolbar and viewer, with a confirm alert and Cmd-Z. Recently Deleted (File Station backed) supports restore and a confirmed permanent delete. Restore and permanent delete refuse paths outside `/home/#recycle/Photos`, refuse a name clash, and wait until the file has left the recycle folder.
- Non-destructive crop and rotate: saves a NEW asset into `/home/Photos/Edited`, the original is untouched.
- DMG installer (`make dmg` or the Xcode `Installer` scheme), Apple Development signed.

Not shipped yet:
- Albums create, add and remove (the Albums browser is read only).
- Favorite toggle, person naming, tag editing.
- Share links (create call shape undocumented, see TODO).
- Import and upload UI.
- Notarization (needs a Developer ID cert).
- QuickConnect or DDNS, Windows UI.

Open risk: nothing checks that the DSM recycle bin is enabled for the homes share. If it is off, delete is permanent while the UI says it can be restored. See TODO.

## Tests (measured 2026-10-16)

- Rust: `cargo test --workspace` from the repo root. 385 passed, 0 failed, 1 ignored (the real NAS test).
- Swift unit tests: 470 passed, 0 failed, 0 skipped. Run with
  `xcodebuild test -project app/MySynologyPhotos.xcodeproj -scheme MySynologyPhotos -destination 'platform=macOS' -only-testing:MySynologyPhotosTests`
  or `scripts/test.sh app`. Use `ADHOC_SIGN=1 scripts/test.sh app` in a shell that cannot see the login keychain (for example a sandboxed agent). Run unit tests only: the UI test target triggers a System Events automation prompt.
- After any core change run `make xcframework` if the build complains about missing `uniffi_..._checksum` (the self-heal watches `core/**/*.rs` only, not `Cargo.toml` or the UDL).
- Falsify new tests: revert the fix, watch the test fail, restore.

## Real NAS probing workflow

Host `fafnir.ladon-pirate.ts.net`, port `5001`, Personal space only (`SYNO.Foto.*`). Shared/`FotoTeam` returns error 801.

- The DSM account has 2FA, and an OTP lives about 30 seconds. On the FIRST probe of a session ask the user for ONE fresh OTP, log in with `enable_device_token=yes`, and save `sid`, `syno_token` and `device_token` to `$CLAUDE_JOB_DIR/tmp/syno_session.txt`. Later probes reuse the `sid`, and re-login with the saved `device_token` (no OTP) if it expired.
- Prefer reproducing through the app's real path (`PhotosCore.login -> probe_capabilities -> crawl_space -> fetch_assets -> thumbnail`) in a throwaway `core/photoscore/examples/*.rs`. Delete it afterwards, never commit it.
- Gotchas: state-reading calls need the `X-SYNO-TOKEN` header (else error 119). Thumbnails and downloads key on `unit_id` (from `additional.thumbnail.unit_id`), not the item id. `SYNO.Foto.Thumbnail` max version is 2. Browse list needs `additional=["thumbnail","resolution"]` for `cache_key` and `unit_id`. Browse.Item must be pinned to version 2 for the enriched `additional`.
- Destructive network calls are blocked under auto mode. Have the user run them from the prompt shell prefix, and back up the original first.
- Secrets hygiene: the session file is session only and never committed. The device token is revocable in DSM. The repo is public, so never write credentials into any tracked file.

## Prioritized next list

1. Recycle bin enabled probe (HIGH): read the recycle setting for the homes share via `SYNO.Core.Share` / `SYNO.Core.RecycleBin`, then warn or block delete when it is off. Also confirm File Station error 408 for a missing folder and the completion polling on the real NAS.
2. Remove the dead trash-album core methods and their FFI exports.
3. Albums: create, add and remove, replacing the sidebar placeholder. Probe each method read-first, with bogus-value controls.
4. Import and upload UI for migrating off iCloud (File Station upload is already in the API client).
5. Notarization: Developer ID cert, then `notarytool submit` and `stapler staple` on the dmg.
6. Smaller items listed in `TODO.md` (editor cache bypass, delete dialog UI tests, clippy and Swift 6 warnings).

## How to work here

- Use subagents for independent work, with disjoint file sets. The app's RootView, Grid and Detail files are hot.
- Commit small and human, straight to `main`, no feature branches, no AI attribution, no dashes used as dashes in prose. Use pathspec commits when siblings are active.
- Keep `TODO.md` and `Fixed.md` in sync: move done items to `Fixed.md` with the commit hash and delete them from `TODO.md`. Plans live in `documentation/plans/`, finished ones in `documentation/plans/done/`.
- Safety invariants (never destroy an original, soft and confirmed delete, never touch iCloud or the phone) are in `CLAUDE.md`.
