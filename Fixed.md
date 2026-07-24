# Fixed — synology-native-photos

Completed work with commit hashes. Newest at top.

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
