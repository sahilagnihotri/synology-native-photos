# TODO — synology-native-photos

Ordered top to bottom. Execution is via subagent-driven development against
`documentation/plans/2026-07-24-phase0-phase1-implementation.md`. Live progress in
`.superpowers/sdd/progress.md`.

## Security (do before real use)

- [ ] Switch the app from the main DSM account to a dedicated least-privilege `photosclient` user (Photos-only, read-only for Phase 0/1). Using main account during dev only. Setup steps in `documentation/phase0-probe-results.md`.

## Now: Building the Rust core (no NAS needed)

- [ ] Task 6: UniFFI boundary crate (`photoscore`) + `core_version()` + bindgen bin
- [ ] Task 7: Makefile `make bindings` + generate Swift bindings + xcframework
- [ ] Task 8: SwiftUI app + link framework + prove FFI end-to-end (milestone: Swift calls Rust)
- [ ] Tasks 14-23: `synology-api` crate (transport+TLS, tolerant decode, 2FA login, capability probe, browse, thumbnail, download)
- [ ] Tasks 24-27: `persistence` crate (schema, windowed asset queries, albums, sync-state)
- [ ] Tasks 28-31: `sync-engine` crate (resumable crawl, clock-skew-safe delta, full suite green)

## Empirical NAS probes (need login; main account for now)

- [ ] Task 10: real 2FA login flow, SID + SynoToken shape
- [ ] Task 11: Browse.Item + Thumbnail + Download response shapes
- [ ] Task 13: delete-semantics probe on a throwaway asset (verdict table)

(Task 9 API.Info version ranges and Task 12 cert already captured; see Fixed.md.)

## Facade + Swift UI (after core)

- [ ] Tasks 32-38: wire Rust core to UniFFI `PhotosCore` (login, crawl, fetch, thumbnail, download)
- [ ] Tasks 39-53: Swift app (Keychain, auth state machine, login+OTP, LAN/Tailscale, thumbnail cache, windowed grid, QuickLook detail, Personal/Shared toggle, sign-out)
- [ ] Tasks 54-58: XCUITests, real-NAS LAN + Tailscale runs, security audit of read-only surface

## Later phases (own plans)

- [ ] Phase 2: safe-delete (trash-move) + albums + search + favorites + real permanent-delete (gated on Task 13 verdict)
- [ ] Phase 3: non-destructive editing (upload-as-new)
- [ ] Phase 4: cross-platform core extraction; QuickConnect/DDNS remote access
