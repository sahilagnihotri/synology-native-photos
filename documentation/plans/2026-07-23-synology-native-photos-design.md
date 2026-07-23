# Synology Native Photos — Design

> Date: 2026-07-23
> Status: DRAFT (awaiting user review)
> Research basis: `documentation/research/2026-07-23-feasibility-research.md`

A native macOS app, Apple Photos-like, that acts as a client to a Synology 925+ NAS over its Web API. It lets the user browse, delete, organize, search, favorite, and non-destructively edit their Synology photo library. Goal: help the user migrate off iCloud while keeping an independent double backup. Mac-first; a reusable core makes a future Windows/Linux/iOS port a UI project, not a rewrite.

## 1. Guiding principle: the app must be provably incapable of losing a photo

The user is migrating off iCloud and will increasingly rely on the NAS. This app can initiate writes against that NAS. Therefore the entire design is organized around one invariant: **no user action in this app can destroy the only copy of a photo.** Every capability below is built to honor it.

### The three safety invariants

1. **Originals are immutable.** Editing never mutates the source file. Edits are stored as a local recipe; the rendered result is uploaded as a *new* asset. "Revert" is trivial because the original was never touched.
2. **Delete is a non-destructive move, then a verified permanent delete.** "Delete" moves the asset into an app-controlled trash folder/album on the NAS via the API's move operation (the file still exists on disk). Permanent removal is a separate, explicitly-gated action, unlocked only after the API's delete semantics are empirically proven recoverable (Phase 0).
3. **Writes fail closed.** Because the Synology Photos API is unofficial and undocumented, any write that gets an unexpected response does *nothing* and surfaces an error. It never guesses, never retries blindly against a state-changing call.

## 2. Scope

### In scope for v1 (delivered across phases)
- Browse: smooth grid scrolling of a 20k-100k library, detail view, download originals.
- Delete: safe (trash-folder move) from day one; verified permanent delete as soon as Phase 0 proves it safe.
- Albums: list, view, move photos between albums (reuses the safe move operation).
- Search & filter: by date, filename, metadata; people/faces if the API exposes them.
- Favorites / ratings: metadata-only writes, re-read after write.
- Non-destructive editing: crop/adjust, original immutable, edited copy uploaded as a new asset.

### Explicitly deferred (future, separate work)
- QuickConnect / DDNS remote access (LAN + Tailscale first).
- Windows / Linux / iOS UI (the Rust core is built to allow it).
- Any iCloud / Mac Photos library integration.

### Explicitly out of scope (safety)
- Calling the raw unofficial `delete` endpoint for real deletion before its semantics are empirically verified.

## 3. Architecture

### 3.1 Overview

```
┌─────────────────────────────────────────────┐
│  macOS app (Swift)                            │
│  SwiftUI shell                                │
│  ├─ NSCollectionView grid (NSViewRepresentable)│  ← windowed, off-main
│  ├─ QuickLook detail                          │
│  └─ Keychain (SID/token)                      │
└───────────────┬───────────────────────────────┘
                │ UniFFI-generated Swift bindings (value types, mapped errors, async)
┌───────────────▼───────────────────────────────┐
│  photos-core (Rust)                            │
│  ├─ synology-api  (HTTP, auth, tolerant decode,│
│  │                 SYNO.API.Info capability probe)
│  ├─ sync-engine   (resumable crawl + delta by  │
│  │                 id/version, fail-closed writes)
│  ├─ persistence   (SQLite: rusqlite/sqlx)      │
│  └─ models         (assets, albums, sync state) │
└───────────────┬───────────────────────────────┘
                │ HTTP(S) over LAN / Tailscale
┌───────────────▼───────────────────────────────┐
│  Synology NAS — Synology Photos                │
│  SYNO.Foto.* (personal) / SYNO.FotoTeam.* (shared)
└────────────────────────────────────────────────┘
```

### 3.2 Core language: Rust + UniFFI (decided)

The core (API client, sync engine, persistence, models) is a Rust workspace exposed to Swift via UniFFI. Rationale: the user has chosen to prioritize a genuinely reusable core (Windows/Linux/iOS/CLI all reuse it unchanged) and the discipline a strongly-typed language enforces on the safety-critical write/sync logic. Speed is *not* the reason (the app is network/IO/OS-codec bound, where Rust and Swift are identical); portability and correctness are.

FFI-friction mitigation:
- A single `make bindings` step regenerates Swift bindings and the xcframework, wired into the Xcode build. Regeneration is one command.
- The core is developed and tested independently in pure Rust (fast loop, property-based tests for sync/safety logic). Swift only sees the stable generated interface.
- The FFI boundary is designed once: plain value types across it, Rust `Result` errors mapped to a Swift error enum, async via UniFFI async support.
- **The core exposes windowed query methods** (`fetch_assets(range)`, `count_by_bucket()`) rather than a shared DB handle, so the grid's windowed data flow works cleanly across the boundary.

### 3.3 UI (Swift)

- SwiftUI for app chrome.
- **AppKit `NSCollectionView`** (wrapped via `NSViewRepresentable`, `NSCollectionViewDiffableDataSource`) for the grid. `LazyVGrid` stutters past a few thousand items; the user has up to 100k. This is the load-bearing UI decision.
- QuickLook (`QLPreviewPanel` / `isQuicklookPreviewable`) for detail/spacebar preview; download-to-temp for remote assets, bounded temp cache. HEIC/RAW/video behavior verified early.

### 3.4 Data flow and performance (addresses review H4)

- The grid **never observes the whole library.** It requests **date-bucketed slices scoped to the visible range** from the core, which reads SQLite off the main thread.
- Sync writes are coalesced into transactions and UI updates are debounced so a background crawl doesn't fire thousands of grid refreshes.
- Thumbnails: server-rendered at grid size, decoded off-main via ImageIO downsampling, held in a byte-cost-limited `NSCache`; never hold 100k `NSImage`s. Prefetch ahead of scroll direction.

### 3.5 Thumbnail cache (addresses review H2)

On-disk cache keyed on **`(asset_id, size_variant, cache_key)` together**, not `cache_key` alone. `cache_key` is treated as a version token, not an identity, and invalidated when it changes on the NAS. Assumption verified by test: edit a photo on the NAS, confirm the thumbnail updates.

### 3.6 Sync correctness (addresses review C3, H3)

- **Delta sync uses the server's own item id + version field as the source of truth, not wall-clock modified-time.** Clock skew between NAS and Mac otherwise creates permanent silent holes. If no reliable version field exists, fall back to periodic full id-set reconciliation (cheap even at 100k).
- The first crawl is **resumable and progress-tracked** (persisted page cursor). An explicit `initial_crawl_complete` barrier plus expected total from the API. Until complete, the UI shows "importing N of M" and never presents a partial library as whole. Final local count is reconciled against the server total; a mismatch is surfaced.

### 3.7 Unofficial-API containment (addresses review H1)

- Every API call goes through a thin **versioned adapter** with **tolerant decoding** (decode what we know, ignore unknown fields, never hard-fail on a missing non-essential key).
- Runtime **capability probe** via `SYNO.API.Info` on connect: discover available APIs and their `minVersion`/`maxVersion`, pin the versions actually requested.
- Every write **fails closed** on an unexpected response.
- A **diagnostic raw-dump mode** logs the request/response of a failing call so a DSM update is a fast re-fix, not a dead app.
- Accepted and documented: this app can break on any DSM update. Read paths degrade to "can't browse" (annoying); write paths fail closed (safe).

### 3.8 Auth & connectivity (addresses review M2, L1)

- Auth via `SYNO.API.Auth`; **2FA/OTP handled from the first login.**
- SID/token stored in the macOS **Keychain** (Data Protection Keychain), never UserDefaults.
- Auth modeled as an explicit **state machine** (`valid` / `expired` / `invalid`); on any auth failure, background work stops and a re-login is prompted rather than spinning.
- Connectivity: LAN + Tailscale first (probe on launch, prefer LAN for originals). Tailscale means DSM's TLS cert won't match a magicDNS name — the cert trust model is decided deliberately (pin/trust), never by disabling TLS validation (that would be a real hole for QuickConnect later). QuickConnect/DDNS deferred.

## 4. Phasing

- **Phase 0 (day one, gating):** Empirically determine the API's delete semantics on a throwaway test library (create → API delete → check DSM recycle bin → check file over SMB). Result gates whether/when real permanent-delete is enabled. Prioritized early so real-delete is unlocked as soon as it's proven safe.
- **Phase 1:** Connect/auth (+2FA, Keychain, capability probe) → resumable progress-tracked crawl into SQLite → windowed `NSCollectionView` grid → detail/QuickLook (HEIC/RAW/video verified). The trustworthy read foundation.
- **Phase 2:** Safe-delete (trash-folder move) + real permanent-delete (once Phase 0 clears it) + albums (view/organize via move) + search/filter + favorites/ratings + background delta sync.
- **Phase 3:** Non-destructive editing (recipe local, upload edited copy as new asset, revert-to-original).
- **Phase 4:** Extract/harden the Rust core for a second platform; QuickConnect/DDNS remote access; LAN/remote auto-switching.

**Effort estimate (honest):** multi-month solo build. Phase 1 alone (smooth 100k-photo browser with resumable sync) is the bulk of the hard infrastructure.

## 5. Testing (all four types, from the start)

- **Core unit + API-contract tests:** unit tests on the Rust core; contract tests that fail when the Synology API response shape drifts (early-warning for DSM breakage).
- **Destructive-action safety tests:** prove delete only ever moves to trash, edit never mutates the original, writes fail closed on unexpected responses. These guard the three invariants and must be green before any release.
- **UI / e2e tests:** XCUITest for grid, detail, delete-confirm flow, and importing-progress states.
- **Performance / soak tests:** scroll-performance and memory against a synthetic 100k-item library; long-running soak of the sync engine (interrupted crawls, expired sessions, DSM restart).

Additional testing suggested for this app class: **security review** of auth/secrets handling and TLS trust (Keychain usage, no token leakage, cert pinning for Tailscale/remote); **chaos/interruption testing** of the sync engine (network drops mid-crawl, clock skew injection).

## 6. Risks / open questions to resolve during implementation

1. **Delete semantics (soft vs hard)** — resolved empirically in Phase 0; until then, only trash-move is used.
2. **DSM version drift** — contained by tolerant decoding + capability probe + fail-closed + diagnostic mode; accepted as an ongoing maintenance cost.
3. **`cache_key` semantics** — verified by the edit-a-photo-on-NAS test; cache keyed on the composite tuple regardless.
4. **UniFFI async + windowed queries across the FFI boundary** — core API surface designed for windowed access from day one; validated with a perf spike early in Phase 1.
5. **Live Photos** — stored on the NAS as two separate files (HEIC still + HEVC MOV); the "live" linkage is not reconstructed. Decide whether to re-pair them in the UI or treat as separate assets.
6. **Second-backup safety gate** — first destructive action requires a one-time acknowledgment that an independent second backup (Hyper Backup / external / offsite) exists, so the app never becomes the thing that loses the last copy.
