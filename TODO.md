# TODO — synology-native-photos

Ordered top to bottom. Work through in sequence; parallelize sub-steps with sub-agents where independent.

## Now: Design phase

- [ ] Digest research (Synology API, iCloud/sync semantics, Mac stack) into a decision-grade summary
- [ ] Decide shared-core language: Rust+UniFFI vs pure-Swift SwiftPM core
- [ ] Adversarial review of the architecture (skeptic sub-agents pressure-test the risky calls)
- [ ] Write design doc to `documentation/plans/YYYY-MM-DD-synology-native-photos-design.md`
- [ ] User reviews and approves the design
- [ ] Write implementation plan (phased) via writing-plans skill

## Phase 1: Read-only browse MVP (safest first)

- [ ] Synology API client: auth (`SYNO.API.Auth`), Keychain-stored session, LAN + Tailscale connect
- [ ] Local SQLite index (GRDB): full paginated crawl of items into DB
- [ ] Two-tier thumbnail cache (memory + on-disk, keyed by `cache_key`)
- [ ] `NSCollectionView` grid over the local index (smooth scroll at 20k-100k)
- [ ] Detail view via QuickLook + download original
- [ ] Tests: core unit tests, API integration tests (mocked + real DSM), grid UI test

## Phase 2: Manage (delete, albums, search)

- [ ] Soft delete + confirm (recycle-bin backed, recoverable)
- [ ] Albums: list, view, create, add/remove
- [ ] Search (by date, filename, metadata; people/faces if API allows)
- [ ] Background delta sync (`NSBackgroundActivityScheduler`)
- [ ] Tests: destructive-action UI tests, sync reconciliation tests

## Phase 3: Edit (non-destructive)

- [ ] Duplicate-before-edit / sidecar model; original always immutable
- [ ] Crop/adjust; render edited copy; upload as new asset
- [ ] Revert-to-original
- [ ] Tests: verify original never mutated (invariant test)

## Phase 4: Cross-platform + remote

- [ ] Extract shared core cleanly; start Windows UI project
- [ ] QuickConnect / DDNS remote access support
- [ ] LAN/remote auto-switching (prefer LAN, fall back to remote)

## Deferred / future (separate projects)

- [ ] iCloud / Mac Photos library integration (out of current scope)
- [ ] Video handling depth (thumbnails, transcoding, playback) if not covered in Phase 1
- [ ] Distribution: Developer ID + notarization vs Mac App Store sandbox
