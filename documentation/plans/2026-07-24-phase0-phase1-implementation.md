# Synology Native Photos — Phase 0 + 1 Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Execute each task in a fresh subagent, in strict numeric order. Each task is TDD: write the failing test, run it to confirm the failure, write the minimal implementation, run it to confirm it passes, then commit. Mark each `- [ ]` checkbox `- [x]` only after its step is verified. Do not skip the run-to-fail step; a test that never failed proves nothing.

**Goal:** Ship a read-only macOS Photos-like client whose Rust core (exposed to SwiftUI/AppKit via UniFFI) authenticates to a Synology NAS with 2FA, crawls Personal and Shared photo spaces into SQLite, and browses them in an NSCollectionView grid with QuickLook detail.

**Architecture:** A Rust cargo workspace (`models`, `synology-api`, `persistence`, `sync-engine`) is exposed to Swift through a single `photoscore` UniFFI boundary crate presenting one `PhotosCore` object with windowed query methods, async-over-Tokio calls, and a fail-closed `CoreError` enum. The Swift app is a SwiftUI shell hosting an AppKit `NSCollectionView` grid (diffable data source reading bounded windows) and a QuickLook detail view, with a `PhotosCoreClient` actor serializing all core access. Every network model decodes what it knows and ignores unknown fields; every space-scoped call carries a `Space` parameter that the core maps to `SYNO.Foto.*` (Personal) or `SYNO.FotoTeam.*` (Shared).

**Tech Stack:** Rust 1.90.0 (rustup, target `aarch64-apple-darwin`), UniFFI 0.28 (proc-macro mode), reqwest 0.12 (`rustls-tls`), rusqlite 0.32 (`bundled`), tokio 1, thiserror, serde/serde_json, mockito (tests). Swift 6.3 / SwiftUI + AppKit + QuickLook, Security framework (Keychain), Network framework (`NWPathMonitor`), ImageIO, Swift Testing + XCTest/XCUITest. Xcode 26.6 on macOS 26.5 arm64. Build glue via a `Makefile` and `xcodegen`.

## Global Constraints

- **Platform/toolchain:** macOS 26 / Swift 6.3 / Rust installed via rustup (pinned 1.90.0). Rust is NOT yet installed; installing it is the very first task.
- **UniFFI boundary:** the Rust core is exposed to Swift only through the `photoscore` UniFFI crate (proc-macro mode, module name `PhotosCore`). Swift never links Rust crates directly; it links the built `PhotosCore.xcframework` and imports the committed `bindings/PhotosCore.swift`.
- **TLS validation is never disabled globally.** `danger_accept_invalid_certs` is forbidden in any committed code path. The only sanctioned trust override is pinning a specific DER via reqwest `.add_root_certificate()` with hostname verification left on, scoped to one client (contract section 2.6).
- **2FA/OTP is mandatory in the login flow from the first login task.** `login` takes `otp_code: Option<String>`; on `OtpRequired` the Swift UI re-prompts and re-calls with the code.
- **Reads only.** Phase 0 and Phase 1 expose NO delete or edit UI and add NO delete/edit code to the core. The only deletion anywhere is the one-time manual Phase 0 delete-semantics probe on a throwaway asset, run by a human against the real NAS.
- **Commit messages** are human-sounding and imperative, never mention Claude/AI or any attribution, and use no em-dashes, en-dashes, or hyphens used as dashes in prose.
- **Personal/Shared space is a first-class core parameter.** Every space-scoped core method takes a `Space`; each local asset row records its space; the grid re-queries by space.

## File Structure

Repo tree after Phase 1 completes:

```
synology-native-photos/
├── Cargo.toml                          # Rust workspace root: [workspace] members = core/*
├── rust-toolchain.toml                 # pins rust 1.90.0, target aarch64-apple-darwin
├── Makefile                            # make bindings, make xcframework, make test-rust, make clean
├── .gitignore                          # target/, build/, *.xcframework staging, DerivedData
│
├── core/                               # Rust cargo workspace (the shared PhotosCore)
│   ├── models/                         # crate: pure data types, no I/O
│   │   ├── Cargo.toml
│   │   └── src/
│   │       └── lib.rs                  # Space, Asset, Album, Session, CrawlProgress, CoreError, MediaKind, ...
│   │
│   ├── synology-api/                   # crate: HTTP client, auth+2FA, capability probe, tolerant serde
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs                  # ApiClient facade, re-exports
│   │       ├── transport.rs            # reqwest client, TLS trust policy, client-side throttle
│   │       ├── auth.rs                 # SYNO.API.Auth login/logout, OTP, SID/SynoToken handling
│   │       ├── info.rs                 # SYNO.API.Info capability probe, version pinning
│   │       ├── browse.rs               # SYNO.Foto(Team).Browse.Item/Album list
│   │       ├── thumbnail.rs            # SYNO.Foto(Team).Thumbnail get
│   │       ├── download.rs             # SYNO.Foto(Team).Download download
│   │       ├── envelope.rs             # SynoResponse<T> tolerant decode, error-code mapping
│   │       └── namespace.rs            # Space -> API namespace string resolver
│   │
│   ├── persistence/                    # crate: SQLite via rusqlite, migrations, windowed queries
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs                  # Store facade
│   │       ├── schema.rs               # embedded CREATE TABLE DDL + migration runner
│   │       ├── assets.rs               # insert/upsert assets, windowed fetch, counts by space
│   │       ├── albums.rs               # album rows
│   │       └── sync_state.rs           # per-space crawl cursor + barrier read/write
│   │
│   ├── sync-engine/                    # crate: resumable crawl + delta by server id/version
│   │   ├── Cargo.toml
│   │   └── src/
│   │       ├── lib.rs                  # PageSource trait, AssetPage, Crawler + delta reconciler modules
│   │       ├── crawl.rs                # paginated resumable crawl loop, progress emission
│   │       └── delta.rs                # delta reconciliation by (id, version) not wall-clock
│   │
│   └── photoscore/                     # crate: THE UniFFI boundary crate (cdylib + staticlib)
│       ├── Cargo.toml                  # crate-type = ["staticlib","cdylib","lib"]; uniffi build dep
│       ├── uniffi.toml                 # bindings config: module name = PhotosCore
│       └── src/
│           ├── lib.rs                  # setup_scaffolding! + #[uniffi::export] PhotosCore object
│           └── bin/
│               └── uniffi-bindgen.rs   # thin: fn main(){ uniffi::uniffi_bindgen_main() }
│
├── bindings/                           # generated Swift bindings (committed, regenerated by make)
│   ├── PhotosCore.swift                # generated Swift API
│   ├── PhotosCoreFFI.h                 # generated C header
│   └── module.modulemap                # generated module map (renamed from PhotosCoreFFI.modulemap)
│
├── PhotosCore.xcframework/             # built by make xcframework (gitignored; build artifact)
│
├── app/                                # SwiftUI macOS app (Xcode project)
│   ├── project.yml                     # xcodegen spec, source of truth for the project
│   ├── SynologyPhotos.xcodeproj/
│   ├── SynologyPhotos/
│   │   ├── SynologyPhotosApp.swift     # @main SwiftUI App entry, scene, root state
│   │   ├── RootView.swift              # AppEnvironment + RootRouter + Library scene
│   │   ├── CoreBridge/
│   │   │   ├── PhotosCoreProtocol.swift # protocol seam; PhotosCore conforms via extension
│   │   │   ├── PhotosCoreClient.swift  # thin Swift actor wrapping the UniFFI PhotosCore object
│   │   │   └── CoreError+Swift.swift   # maps CoreError enum to user-facing strings
│   │   ├── Auth/
│   │   │   ├── AuthStateMachine.swift  # valid/expired/invalid + 2FA state
│   │   │   ├── LoginView.swift         # host/user/pass/OTP form
│   │   │   └── KeychainSID.swift       # SID store/load/clear (Security framework)
│   │   ├── Grid/
│   │   │   ├── PhotoGridView.swift     # NSViewControllerRepresentable wrapper
│   │   │   ├── PhotoGridController.swift # NSCollectionView + NSCollectionViewDiffableDataSource
│   │   │   ├── PhotoCellView.swift     # NSCollectionViewItem cell
│   │   │   └── WindowedDataSource.swift # bridges windowed fetch_assets to diffable snapshot
│   │   ├── Thumbnails/
│   │   │   ├── ThumbnailCache.swift    # two-tier: NSCache (byte-cost) + on-disk composite key
│   │   │   └── ImageDownsample.swift   # ImageIO off-main downsample
│   │   ├── Detail/
│   │   │   └── DetailQuickLookView.swift # QuickLook, download-to-temp, bounded temp cache
│   │   ├── Session/
│   │   │   ├── SpaceToggle.swift       # Personal/Shared segmented control -> re-query
│   │   │   ├── SignOutController.swift # clean teardown: SID clear, per-account cache wipe
│   │   │   └── CrawlProgressModel.swift # "importing N of M" gated on the crawl barrier
│   │   ├── Reachability/
│   │   │   └── PathMonitor.swift       # NWPathMonitor wrapper + HostSelector
│   │   ├── UITestSupport/
│   │   │   └── UITestFixture.swift     # DEBUG-only fake core for XCUITests
│   │   └── Resources/
│   │       └── Assets.xcassets
│   ├── SynologyPhotosTests/
│   │   ├── FakePhotosCore.swift
│   │   ├── FakePhotosCoreTests.swift
│   │   ├── PhotosCoreClientTests.swift
│   │   ├── KeychainSIDTests.swift
│   │   ├── AuthStateMachineTests.swift
│   │   ├── LoginViewModelTests.swift
│   │   ├── PathMonitorTests.swift
│   │   ├── ImageDownsampleTests.swift
│   │   ├── ThumbnailCacheTests.swift
│   │   ├── WindowedDataSourceTests.swift
│   │   ├── PhotoGridControllerTests.swift
│   │   ├── SpaceToggleTests.swift
│   │   ├── CrawlProgressModelTests.swift
│   │   ├── TempCacheTests.swift
│   │   ├── SignOutControllerTests.swift
│   │   ├── RootRouterTests.swift
│   │   ├── CoreBridgeSmokeTests.swift
│   │   └── RealNASIntegrationTests.swift
│   └── SynologyPhotosUITests/
│       └── LibraryFlowUITests.swift
│
├── documentation/
│   ├── plans/
│   │   ├── 2026-07-23-synology-native-photos-design.md   # approved design (exists)
│   │   └── 2026-07-24-phase0-phase1-implementation.md    # THIS plan
│   ├── phase0-probe-results.md         # filled by Phase 0 empirical probes (real NAS facts)
│   └── research/
│       └── 2026-07-23-feasibility-research.md            # exists
│
├── CLAUDE.md
├── LICENSE
└── TODO.md
```

Crate dependency DAG (no cycles): `models` <- `synology-api`, `persistence`; `synology-api` + `persistence` <- `sync-engine`; all four <- `photoscore`. Only `photoscore` depends on uniffi.

---

## Phase 0: Foundations, empirical probes, scaffolding

Tasks 1 through 8 are a serial critical path everyone waits on. After Task 8 (`make bindings` produces the committed Swift file), Groups B, C, and D parallelize. The empirical NAS probes (Tasks 3, 9, 10, 11, 12) are human-run against the real NAS and can proceed in parallel with the scaffolding; they inform the API facts but do not block compilation because the interface contract is authoritative and every network model decodes tolerantly.

### Task 1: Install Rust toolchain and pin it, add the Apple Silicon target

**Files**
- Create: `/Users/sahil/code/github/synology-native-photos/rust-toolchain.toml`

**Interfaces**
- Consumes: nothing (bootstrap).
- Produces: a working `rustc`/`cargo` on `PATH` at pinned `1.90.0`; installed target `aarch64-apple-darwin`. The pinned toolchain file is consumed by every later Rust task.

**TDD steps**

- [ ] Write the failing verification. There is no code file yet; the verification IS the command below, expected to fail because Rust is absent. Record expected pre-state:
  ```
  rustc --version   # expected: "command not found" (non-zero exit)
  ```
- [ ] Run-to-fail:
  ```
  rustc --version
  ```
  Expected: `zsh: command not found: rustc`, non-zero exit.
- [ ] Minimal implementation. Install rustup non-interactively, pin the toolchain, add the target:
  ```
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.90.0 --profile minimal
  source "$HOME/.cargo/env"
  rustup toolchain install 1.90.0 --profile minimal
  rustup default 1.90.0
  rustup target add aarch64-apple-darwin
  ```
  Then create `rust-toolchain.toml`:
  ```toml
  [toolchain]
  channel = "1.90.0"
  targets = ["aarch64-apple-darwin"]
  profile = "minimal"
  ```
- [ ] Run-to-pass:
  ```
  source "$HOME/.cargo/env"
  rustc --version
  rustup target list --installed | grep aarch64-apple-darwin
  ```
  Expected: `rustc 1.90.0 (...)` and a line `aarch64-apple-darwin`, both exit 0.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add rust-toolchain.toml
  git commit -m "Pin Rust toolchain to 1.90.0 with aarch64-apple-darwin target"
  ```

---

### Task 2: Create the cargo workspace and five empty crate skeletons with the dependency DAG

**Files**
- Create: `/Users/sahil/code/github/synology-native-photos/Cargo.toml` (workspace root)
- Create: `core/models/Cargo.toml`, `core/models/src/lib.rs`
- Create: `core/synology-api/Cargo.toml`, `core/synology-api/src/lib.rs`
- Create: `core/persistence/Cargo.toml`, `core/persistence/src/lib.rs`
- Create: `core/sync-engine/Cargo.toml`, `core/sync-engine/src/lib.rs`
- Create: `core/photoscore/Cargo.toml`, `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: pinned toolchain from Task 1.
- Produces: buildable workspace with crate DAG `models <- {synology-api, persistence}`, `{synology-api, persistence} <- sync-engine`, `{all four} <- photoscore`. Only `photoscore` gains a uniffi dep (added in Task 6, not here).

**TDD steps**

- [ ] Write the failing test. Put a trivial marker test in `models` so the workspace has a real `cargo test` target. Create `core/models/src/lib.rs` with only the test:
  ```rust
  #[cfg(test)]
  mod tests {
      #[test]
      fn crate_marker_is_present() {
          assert_eq!(crate::CRATE_MARKER, "models");
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p models 2>&1 | head -40
  ```
  Expected: compile error `cannot find value CRATE_MARKER in crate root` (or `could not find Cargo.toml` before the workspace manifest exists), non-zero exit.
- [ ] Minimal implementation. Create the workspace root `Cargo.toml`:
  ```toml
  [workspace]
  resolver = "2"
  members = [
      "core/models",
      "core/synology-api",
      "core/persistence",
      "core/sync-engine",
      "core/photoscore",
  ]

  [workspace.package]
  edition = "2021"
  version = "0.1.0"
  license = "MIT"

  [workspace.dependencies]
  thiserror = "1"
  serde = { version = "1", features = ["derive"] }
  serde_json = "1"
  tracing = "0.1"
  tokio = { version = "1", features = ["rt-multi-thread", "macros"] }
  reqwest = { version = "0.12", default-features = false, features = ["json", "rustls-tls", "stream"] }
  rusqlite = { version = "0.32", features = ["bundled"] }
  async-trait = "0.1"
  ```
  `core/models/Cargo.toml`:
  ```toml
  [package]
  name = "models"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [dependencies]
  thiserror.workspace = true
  serde.workspace = true
  ```
  Add the marker const to the top of `core/models/src/lib.rs` (above the test module):
  ```rust
  //! Pure data types for synology-native-photos. No I/O.

  pub const CRATE_MARKER: &str = "models";
  ```
  `core/synology-api/Cargo.toml`:
  ```toml
  [package]
  name = "synology-api"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [dependencies]
  models = { path = "../models" }
  thiserror.workspace = true
  serde.workspace = true
  serde_json.workspace = true
  tracing.workspace = true
  reqwest.workspace = true
  ```
  `core/synology-api/src/lib.rs`:
  ```rust
  //! Synology Web API HTTP client, auth, capability probe, tolerant decode.
  ```
  `core/persistence/Cargo.toml`:
  ```toml
  [package]
  name = "persistence"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [dependencies]
  models = { path = "../models" }
  thiserror.workspace = true
  rusqlite.workspace = true
  tracing.workspace = true
  ```
  `core/persistence/src/lib.rs`:
  ```rust
  //! SQLite persistence via rusqlite: migrations and windowed queries.
  ```
  `core/sync-engine/Cargo.toml`:
  ```toml
  [package]
  name = "sync-engine"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [dependencies]
  models = { path = "../models" }
  synology-api = { path = "../synology-api" }
  persistence = { path = "../persistence" }
  thiserror.workspace = true
  tracing.workspace = true
  async-trait.workspace = true

  [dev-dependencies]
  tokio = { version = "1", features = ["macros", "rt"] }
  ```
  `core/sync-engine/src/lib.rs`:
  ```rust
  //! Resumable progress-tracked crawl and delta reconciliation by server id/version.
  ```
  `core/photoscore/Cargo.toml` (uniffi added later in Task 6; keep it building now):
  ```toml
  [package]
  name = "photoscore"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [dependencies]
  models = { path = "../models" }
  synology-api = { path = "../synology-api" }
  persistence = { path = "../persistence" }
  sync-engine = { path = "../sync-engine" }
  thiserror.workspace = true
  tracing.workspace = true
  ```
  `core/photoscore/src/lib.rs`:
  ```rust
  //! The UniFFI boundary crate exposing PhotosCore to Swift.
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos && cargo build --workspace && cargo test -p models 2>&1 | tail -20
  ```
  Expected: `cargo build --workspace` finishes `Finished`; `cargo test -p models` reports `test tests::crate_marker_is_present ... ok`.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add Cargo.toml core/
  git commit -m "Scaffold cargo workspace with five core crates and dependency graph"
  ```

---

### Task 3: Document the dedicated DSM Photos-only user setup and the manual delete-semantics probe procedure

**Files**
- Create: `/Users/sahil/code/github/synology-native-photos/documentation/phase0-probe-results.md`

**Interfaces**
- Consumes: nothing in code. NO delete code is added to any crate; this task records the manual procedure and a placeholder verdict for the human/Author B to fill against the real NAS.
- Produces: `documentation/phase0-probe-results.md` with (a) the dedicated DSM Photos-only user setup steps, and (b) the step-by-step manual delete-semantics probe procedure and a results table. The other empirical probe sections (API.Info, login/2FA, browse/thumbnail/download shapes, cert DER) are appended by Tasks 9, 10, 11, 12 to the same file; this task creates the file and the two sections it owns.

**TDD steps**

- [ ] Write the failing verification (shell check; file does not exist yet):
  ```
  cd /Users/sahil/code/github/synology-native-photos && test -f documentation/phase0-probe-results.md && grep -q "## Dedicated DSM Photos-only user" documentation/phase0-probe-results.md && grep -q "## Delete-semantics probe procedure" documentation/phase0-probe-results.md && echo PASS || echo FAIL
  ```
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos && test -f documentation/phase0-probe-results.md && echo EXISTS || echo MISSING
  ```
  Expected: `MISSING`.
- [ ] Minimal implementation. Create `documentation/phase0-probe-results.md`:
  ```markdown
  # Phase 0 Probe Results

  Empirical facts captured against the real Synology NAS. Sections owned by Author A
  (user setup, delete-semantics procedure) and Author B (API.Info, login/2FA, browse
  and media shapes, cert DER) are appended to this one file. Treat the API facts as a
  moving target: version-guard and decode tolerantly against what is recorded here.

  Read-only invariant: nothing in Phase 0/1 adds delete or edit code to the core. The
  only deletion in Phase 0 is the manual, human-run probe below on a throwaway asset,
  performed to characterize semantics. Its verdict informs future phases only.

  ## Dedicated DSM Photos-only user

  Purpose: the app authenticates as a dedicated, least-privilege DSM account that can
  reach Synology Photos and nothing else. This isolates the app's blast radius and
  keeps 2FA scoped to an account we control.

  Setup steps (DSM 7.x, Control Panel):

  1. Control Panel -> User & Group -> User -> Create.
     - Name: photosclient
     - Description: "Dedicated account for synology-native-photos client"
     - Password: strong, stored only in the developer's password manager (never in the repo).
  2. User Groups: assign to users only. Do NOT add to administrators.
  3. Permissions (shared folders): grant Read only to the /photo shared folder for
     Phase 0/1 (read-only). No access to other shares.
  4. Applications: deny all applications except Synology Photos. This blocks File
     Station, DSM desktop, etc.
  5. Two-factor authentication: enroll 2FA for this account. Mandatory: the login flow
     handles OTP from the first login task. Record the enrolled method.
  6. Quota/speed: leave defaults; not relevant to a read client.

  Verification (human, before Phase 1 login work):
  - Log in to DSM web as photosclient: only Synology Photos should be reachable.
  - Confirm a 2FA prompt appears at login (proves OTP path is exercised).

  Notes:
  - The account's SID is stored by the app in the macOS Keychain (KeychainSID), never
    on disk in plaintext, never in the repo.
  - The project decision is 2FA stays ON.

  ## Delete-semantics probe procedure

  Purpose: characterize what a Synology Photos API delete actually does (move to a
  recycle bin / trash vs permanent unlink) BEFORE any delete feature is designed. This
  is a one-time manual probe. No delete code is added to the core in Phase 0/1.

  Preconditions:
  - A throwaway image uploaded to Personal Space specifically for this probe.
  - A captured, working SID + SynoToken from the login probe (Task 10).
  - The throwaway asset's id, unit_id, and cache_key from a Browse.Item list.

  Procedure (run by a human against the real NAS; record every response verbatim):

  1. Confirm the asset is listed via SYNO.Foto.Browse.Item method=list; record id, unit_id, cache_key.
  2. Observe the DSM Recycle Bin / trash state before delete (item count; SMB path if mounted).
  3. Issue the delete call (manual curl, throwaway asset only). The exact API/method is
     UNVERIFIED here on purpose; record what the real NAS exposes. Candidate observed in
     the wild is SYNO.Foto.Browse.Item method=delete with an id array:
     ```
     curl -sk "https://<HOST>:5001/photo/webapi/entry.cgi" \
       --data-urlencode "api=SYNO.Foto.Browse.Item" \
       --data-urlencode "method=delete" \
       --data-urlencode "version=1" \
       --data-urlencode "id=[<THROWAWAY_ID>]" \
       --data-urlencode "_sid=<SID>" \
       -H "X-SYNO-TOKEN: <SYNO_TOKEN>"
     ```
     Record: HTTP status, success flag, any error.code.
  4. Re-check state AFTER delete: still in Browse.Item list? in a trash location (API/album)?
     SMB file gone or moved to #recycle (path)? separate permanent-delete / empty-trash API?
  5. If a trash location holds it, probe the permanent-delete step separately (still on the throwaway).

  ### Delete-semantics verdict (fill against real NAS)

  | Field | Value |
  |-------|-------|
  | Date probed | pending |
  | DSM version | pending |
  | Delete API + method used | pending |
  | Delete request version | pending |
  | Response success/error.code | pending |
  | After delete: still in Browse.Item list? | pending |
  | After delete: appears in DSM trash/Recently Deleted? (API/album name) | pending |
  | After delete: SMB file gone or moved to #recycle? (path) | pending |
  | Separate permanent-delete / empty-trash API? (name+method) | pending |
  | Verdict: trash-move then gated permanent-delete confirmed? | pending |
  | Notes / surprises | pending |

  Design implication (locked project invariant): whatever this probe finds, the future
  delete feature will be trash-move first, then a gated permanent-delete, with writes
  failing closed. Phase 0/1 ship NO delete UI and NO delete code in the core.
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos && test -f documentation/phase0-probe-results.md && grep -q "## Dedicated DSM Photos-only user" documentation/phase0-probe-results.md && grep -q "## Delete-semantics probe procedure" documentation/phase0-probe-results.md && echo PASS || echo FAIL
  ```
  Expected: `PASS`.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add documentation/phase0-probe-results.md
  git commit -m "Document dedicated Photos user setup and delete-semantics probe procedure"
  ```

---

### Task 4: Add .gitignore for Rust, Swift, and Xcode build artifacts

**Files**
- Create: `/Users/sahil/code/github/synology-native-photos/.gitignore`

**Interfaces**
- Consumes: nothing.
- Produces: ignore rules so that `target/`, `PhotosCore.xcframework/`, `DerivedData/`, and Swift/Xcode user state never get committed. `bindings/` is NOT ignored (it is a committed source of truth per the contract).

**TDD steps**

- [ ] Write the failing verification. Establish the failing pre-state (a build artifact from Task 2 is currently seen by git):
  ```
  cd /Users/sahil/code/github/synology-native-photos && git status --porcelain | grep '^?? target/'
  ```
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos && git status --porcelain | grep '^?? target/'
  ```
  Expected: at least one line like `?? target/`, exit 0 (grep matched), confirming `target/` is currently untracked and would be committed.
- [ ] Minimal implementation. Create `.gitignore`:
  ```gitignore
  # Rust
  /target
  **/*.rs.bk
  Cargo.lock.orig

  # UniFFI / build artifacts (bindings/ is committed on purpose, not ignored)
  /PhotosCore.xcframework
  /build

  # Xcode
  app/DerivedData/
  app/**/xcuserdata/
  app/**/*.xcuserstate
  *.xcuserstate
  **/xcuserdata/
  DerivedData/

  # macOS
  .DS_Store

  # Swift Package Manager
  .build/
  .swiftpm/
  ```
  Note: `Cargo.lock` at the workspace root IS committed (this is an application workspace), so it is deliberately absent from the ignore list.
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos && git status --porcelain | grep '^?? target/'; echo "exit=$?"
  cd /Users/sahil/code/github/synology-native-photos && git check-ignore -v bindings 2>/dev/null; echo "bindings-ignored-exit=$?"
  ```
  Expected: no `target/` line printed, `exit=1`; nothing printed for `bindings`, `bindings-ignored-exit=1` (not ignored).
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add .gitignore
  git commit -m "Add gitignore for Rust, Swift and Xcode build output"
  ```

---

### Task 5: Define the `models` crate contract types with UniFFI derives and round-trip tests

**Files**
- Modify: `core/models/Cargo.toml`
- Modify: `core/models/src/lib.rs` (types + inline `#[cfg(test)]` module)

**Interfaces**
- Consumes: `uniffi` and `thiserror`.
- Produces (exact, per contract section 2.1 / 2.2): enums `Space { Personal, Shared }`, `MediaKind { Photo, Video, Unknown }`, `ThumbnailSize { Sm, M, Xl }`, `SessionState { Valid, Expired, Invalid }`; records `Connection`, `Session`, `Asset`, `Album`, `CrawlProgress`, `ApiCapability`, `ThumbnailData`; error enum `CoreError` with all eight variants. Consumed by every later Rust task.

**TDD steps**

- [ ] Write the failing test. Replace the placeholder test module in `core/models/src/lib.rs` with contract-type round-trip tests (types do not exist yet, so this fails to compile):
  ```rust
  #[cfg(test)]
  mod tests {
      use crate::*;

      #[test]
      fn crate_marker_is_present() {
          assert_eq!(CRATE_MARKER, "models");
      }

      #[test]
      fn asset_holds_all_contract_fields() {
          let a = Asset {
              id: 42,
              cache_key: "ck-1".to_string(),
              filename: "IMG_0001.HEIC".to_string(),
              media_kind: MediaKind::Photo,
              taken_at: Some(1_700_000_000),
              added_at: None,
              width: Some(4032),
              height: Some(3024),
              file_size: Some(2_500_000),
              space: Space::Personal,
              server_version: Some(7),
          };
          assert_eq!(a.id, 42);
          assert_eq!(a.space, Space::Personal);
          assert_eq!(a.media_kind, MediaKind::Photo);
          assert_eq!(a.width, Some(4032));
      }

      #[test]
      fn connection_shape() {
          let c = Connection {
              host: "https://192.168.1.10:5001".to_string(),
              verify_tls: true,
              pinned_cert_der: None,
          };
          assert!(c.verify_tls);
          assert!(c.pinned_cert_der.is_none());
      }

      #[test]
      fn session_optionals() {
          let s = Session {
              sid: "SID123".to_string(),
              syno_token: Some("tok".to_string()),
              username: "photobot".to_string(),
              device_did: None,
          };
          assert_eq!(s.username, "photobot");
          assert_eq!(s.syno_token.as_deref(), Some("tok"));
      }

      #[test]
      fn crawl_progress_barrier_flag() {
          let p = CrawlProgress { space: Space::Shared, done: 10, total: 100, complete: false };
          assert!(!p.complete);
          assert_eq!(p.space, Space::Shared);
      }

      #[test]
      fn core_error_display_messages() {
          let e = CoreError::Auth { message: "bad pw".to_string() };
          assert_eq!(e.to_string(), "authentication failed: bad pw");
          assert_eq!(CoreError::OtpRequired.to_string(), "two-factor code required or incorrect");
          assert_eq!(CoreError::WriteRefused.to_string(), "write refused: read-only mode");
          let cap = CoreError::CapabilityUnavailable { api: "SYNO.Foto.Browse.Item".to_string() };
          assert_eq!(cap.to_string(), "capability unavailable: SYNO.Foto.Browse.Item");
      }

      #[test]
      fn thumbnail_size_variants_distinct() {
          assert_ne!(ThumbnailSize::Sm, ThumbnailSize::Xl);
          assert_eq!(ThumbnailSize::M, ThumbnailSize::M);
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos && cargo test -p models 2>&1 | head -40
  ```
  Expected: compile errors `cannot find type Asset in this scope`, `cannot find type CoreError in this scope`, etc.
- [ ] Minimal implementation. Add `uniffi` to `core/models/Cargo.toml` dependencies:
  ```toml
  [dependencies]
  thiserror.workspace = true
  serde.workspace = true
  uniffi = { version = "0.28" }
  ```
  Add the types to the top of `core/models/src/lib.rs` (keep `CRATE_MARKER` and the test module):
  ```rust
  //! Pure data types for synology-native-photos. No I/O.

  pub const CRATE_MARKER: &str = "models";

  #[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
  pub enum Space { Personal, Shared }

  #[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
  pub enum MediaKind { Photo, Video, Unknown }

  #[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
  pub enum ThumbnailSize { Sm, M, Xl }

  #[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
  pub enum SessionState { Valid, Expired, Invalid }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct Connection {
      pub host: String,
      pub verify_tls: bool,
      pub pinned_cert_der: Option<Vec<u8>>,
  }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct Session {
      pub sid: String,
      pub syno_token: Option<String>,
      pub username: String,
      pub device_did: Option<String>,
  }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct Asset {
      pub id: i64,
      pub cache_key: String,
      pub filename: String,
      pub media_kind: MediaKind,
      pub taken_at: Option<i64>,
      pub added_at: Option<i64>,
      pub width: Option<u32>,
      pub height: Option<u32>,
      pub file_size: Option<u64>,
      pub space: Space,
      pub server_version: Option<i64>,
  }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct Album {
      pub id: i64,
      pub name: String,
      pub item_count: u32,
      pub cover_cache_key: Option<String>,
      pub space: Space,
  }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct CrawlProgress {
      pub space: Space,
      pub done: u64,
      pub total: u64,
      pub complete: bool,
  }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct ApiCapability {
      pub name: String,
      pub path: String,
      pub min_version: u32,
      pub max_version: u32,
  }

  #[derive(uniffi::Record, Clone, Debug)]
  pub struct ThumbnailData {
      pub cached_path: String,
      pub bytes: Vec<u8>,
  }

  #[derive(uniffi::Error, Debug, thiserror::Error)]
  pub enum CoreError {
      #[error("authentication failed: {message}")]
      Auth { message: String },

      #[error("two-factor code required or incorrect")]
      OtpRequired,

      #[error("network error: {message}")]
      Network { message: String },

      #[error("decode error: {message}")]
      Decode { message: String },

      #[error("unexpected server response: {message}")]
      UnexpectedResponse { message: String },

      #[error("write refused: read-only mode")]
      WriteRefused,

      #[error("storage error: {message}")]
      Storage { message: String },

      #[error("capability unavailable: {api}")]
      CapabilityUnavailable { api: String },
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos && cargo test -p models 2>&1 | tail -25
  ```
  Expected: `test result: ok. 7 passed; 0 failed`.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add core/models/Cargo.toml core/models/src/lib.rs
  git commit -m "Define shared model types and CoreError with UniFFI derives"
  ```

---

### Task 6: Scaffold the `photoscore` UniFFI boundary crate with `core_version()` and the bindgen bin

**Files**
- Modify: `core/photoscore/Cargo.toml`
- Modify: `core/photoscore/src/lib.rs` (+ inline `#[cfg(test)]`)
- Create: `core/photoscore/src/bin/uniffi-bindgen.rs`
- Create: `core/photoscore/uniffi.toml`

**Interfaces**
- Consumes: `models` crate types from Task 5.
- Produces: crate with `crate-type = ["staticlib","cdylib","lib"]`; `uniffi::setup_scaffolding!("photoscore")`; a `#[uniffi::export]` free function `pub fn core_version() -> String`; a `uniffi-bindgen` binary; `uniffi.toml` with `module_name = "PhotosCore"`. Consumed by Task 7 (Makefile), Task 8 (Xcode). The full `PhotosCore` object is added later by Tasks 24 through 29.

**TDD steps**

- [ ] Write the failing test. Add a test in `core/photoscore/src/lib.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      #[test]
      fn core_version_matches_cargo_pkg_version() {
          assert_eq!(crate::core_version(), env!("CARGO_PKG_VERSION"));
          assert_eq!(crate::core_version(), "0.1.0");
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore 2>&1 | head -30
  ```
  Expected: compile error `cannot find function core_version in crate root`.
- [ ] Minimal implementation. Rewrite `core/photoscore/Cargo.toml`:
  ```toml
  [package]
  name = "photoscore"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [lib]
  crate-type = ["staticlib", "cdylib", "lib"]
  name = "photoscore"

  [dependencies]
  models = { path = "../models" }
  synology-api = { path = "../synology-api" }
  persistence = { path = "../persistence" }
  sync-engine = { path = "../sync-engine" }
  thiserror.workspace = true
  tracing.workspace = true
  uniffi = { version = "0.28", features = ["tokio"] }
  tokio = { version = "1", features = ["rt-multi-thread"] }

  [build-dependencies]
  uniffi = { version = "0.28", features = ["build"] }

  [[bin]]
  name = "uniffi-bindgen"
  path = "src/bin/uniffi-bindgen.rs"
  ```
  Rewrite `core/photoscore/src/lib.rs` (proc-macro mode: `setup_scaffolding!` replaces any build.rs/UDL step; no build.rs file is created):
  ```rust
  //! The UniFFI boundary crate exposing PhotosCore to Swift.

  uniffi::setup_scaffolding!("photoscore");

  /// Trivial cross-boundary smoke function. Returns the core crate version.
  /// Proves Swift can call into Rust over UniFFI before the full PhotosCore lands.
  #[uniffi::export]
  pub fn core_version() -> String {
      env!("CARGO_PKG_VERSION").to_string()
  }

  #[cfg(test)]
  mod tests {
      #[test]
      fn core_version_matches_cargo_pkg_version() {
          assert_eq!(crate::core_version(), env!("CARGO_PKG_VERSION"));
          assert_eq!(crate::core_version(), "0.1.0");
      }
  }
  ```
  Create `core/photoscore/src/bin/uniffi-bindgen.rs`:
  ```rust
  fn main() {
      uniffi::uniffi_bindgen_main()
  }
  ```
  Create `core/photoscore/uniffi.toml`:
  ```toml
  [bindings.swift]
  module_name = "PhotosCore"
  cdylib_name = "photoscore"
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos && cargo test -p photoscore 2>&1 | tail -20 && cargo build --release -p photoscore --target aarch64-apple-darwin 2>&1 | tail -5
  ```
  Expected: `test result: ok. 1 passed`; release build `Finished`; artifact `target/aarch64-apple-darwin/release/libphotoscore.a` exists.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add core/photoscore/
  git commit -m "Set up photoscore UniFFI crate with core_version and bindgen binary"
  ```

---

### Task 7: Write the Makefile and generate the committed Swift bindings + xcframework

**Files**
- Create: `/Users/sahil/code/github/synology-native-photos/Makefile`
- Create (generated, committed): `bindings/PhotosCore.swift`, `bindings/PhotosCoreFFI.h`, `bindings/module.modulemap`

**Interfaces**
- Consumes: `libphotoscore.a` and `core_version` from Task 6.
- Produces: `make test-rust`, `make bindings`, `make xcframework`, `make clean`; a committed `bindings/PhotosCore.swift` exporting `func coreVersion() -> String`; `PhotosCore.xcframework` build artifact (gitignored). This is the serialization barrier: after this task, `bindings/PhotosCore.swift` is frozen for Group D, and B/C parallelize.

**TDD steps**

- [ ] Write the failing verification (shell check; the Makefile does not exist yet):
  ```
  cd /Users/sahil/code/github/synology-native-photos && test -f bindings/PhotosCore.swift && grep -q "func coreVersion" bindings/PhotosCore.swift && echo PASS || echo FAIL
  ```
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos && make bindings 2>&1 | head -5
  ```
  Expected: `make: *** No rule to make target 'bindings'`, non-zero exit; the shell check prints `FAIL`.
- [ ] Minimal implementation. Create `Makefile` (use real tab indentation for recipe lines):
  ```makefile
  RUST_TARGETS = aarch64-apple-darwin
  LIB = target/aarch64-apple-darwin/release/libphotoscore.a
  BINDINGS_DIR = bindings
  XCF = PhotosCore.xcframework

  .PHONY: test-rust bindings xcframework clean

  test-rust:
  	cargo test --workspace

  # 1) build the static lib, 2) generate Swift bindings from the built lib
  bindings:
  	cargo build --release -p photoscore --target aarch64-apple-darwin
  	cargo run --release -p photoscore --bin uniffi-bindgen -- \
  		generate --library target/aarch64-apple-darwin/release/libphotoscore.a \
  		--language swift --out-dir $(BINDINGS_DIR)
  	mv $(BINDINGS_DIR)/PhotosCoreFFI.modulemap $(BINDINGS_DIR)/module.modulemap 2>/dev/null || true

  # package the static lib + headers into an xcframework the app links
  xcframework: bindings
  	rm -rf $(XCF)
  	xcodebuild -create-xcframework \
  		-library target/aarch64-apple-darwin/release/libphotoscore.a \
  		-headers $(BINDINGS_DIR) \
  		-output $(XCF)

  clean:
  	cargo clean && rm -rf $(BINDINGS_DIR) $(XCF)
  ```
  Rationale for two deltas from the raw contract snippet, both behavior-preserving on the sanctioned recipes: `LIB` points at the target-scoped path because Task 6 builds with `--target aarch64-apple-darwin`, which places artifacts under the triple subdir (the `bindings`/`xcframework` recipes already use the scoped path); and `rm -rf $(XCF)` precedes `-create-xcframework` because `xcodebuild` refuses to overwrite an existing output, keeping `make xcframework` idempotent.
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos && make bindings 2>&1 | tail -10
  cd /Users/sahil/code/github/synology-native-photos && test -f bindings/PhotosCore.swift && grep -q "func coreVersion" bindings/PhotosCore.swift && echo PASS || echo FAIL
  ls -la bindings/
  cd /Users/sahil/code/github/synology-native-photos && make xcframework 2>&1 | tail -5 && ls -d PhotosCore.xcframework
  ```
  Expected: `make bindings` finishes; `PASS`; `bindings/` contains `PhotosCore.swift`, `PhotosCoreFFI.h`, `module.modulemap`; `xcodebuild` prints `xcframework successfully written out to: .../PhotosCore.xcframework`; the directory exists.
- [ ] Commit (the xcframework is gitignored per Task 4):
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add Makefile bindings/
  git commit -m "Add Makefile and generate committed Swift bindings for the core"
  ```

---

### Task 8: Create the SwiftUI macOS app project, link the framework, and prove the FFI boundary end to end

**Files**
- Create: `app/project.yml` (xcodegen spec)
- Create: `app/SynologyPhotos.xcodeproj/` (generated by xcodegen)
- Create: `app/SynologyPhotos/SynologyPhotosApp.swift`
- Create: `app/SynologyPhotos/Resources/Assets.xcassets/Contents.json`
- Create: `app/SynologyPhotosTests/CoreBridgeSmokeTests.swift`

**Interfaces**
- Consumes: `PhotosCore.xcframework` (Task 7), `bindings/PhotosCore.swift` (Task 7), `coreVersion() -> String`.
- Produces: an Xcode app target `SynologyPhotos` (macOS, arm64, deployment `macosx26.0`), a unit-test target `SynologyPhotosTests`, and a UI-test target `SynologyPhotosUITests`, all linking the framework and able to `import PhotosCore`; a passing XCTest that calls `coreVersion()` across the FFI. Consumed by every Group D task.

**TDD steps**

- [ ] Write the failing test/verification. First establish the project does not exist:
  ```
  cd /Users/sahil/code/github/synology-native-photos && ls app/SynologyPhotos.xcodeproj 2>&1
  ```
  Expected: `No such file or directory`. Then author the smoke test `app/SynologyPhotosTests/CoreBridgeSmokeTests.swift`:
  ```swift
  import XCTest
  import PhotosCore

  final class CoreBridgeSmokeTests: XCTestCase {
      func testCoreVersionCrossesTheFfiBoundary() {
          XCTAssertEqual(coreVersion(), "0.1.0",
                         "Rust core_version() must cross UniFFI and equal the crate version")
      }
      func testCoreVersionIsNonEmpty() {
          XCTAssertFalse(coreVersion().isEmpty)
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS,arch=arm64' 2>&1 | tail -5
  ```
  Expected: failure because the project does not exist. To demonstrate a true red once the project builds, temporarily change the first assertion to `XCTAssertEqual(coreVersion(), "9.9.9")` and observe `("0.1.0") is not equal to ("9.9.9")`, proving the value truly comes from Rust; then restore `"0.1.0"`.
- [ ] Minimal implementation. Install `xcodegen` if absent (self-heal):
  ```
  which xcodegen >/dev/null 2>&1 || brew install xcodegen
  ```
  Create `app/project.yml`:
  ```yaml
  name: SynologyPhotos
  options:
    bundleIdPrefix: com.sahil.synologyphotos
    deploymentTarget:
      macOS: "26.0"
    createIntermediateGroups: true
  settings:
    base:
      SWIFT_VERSION: "6.0"
      ARCHS: arm64
      ONLY_ACTIVE_ARCH: YES
      MACOSX_DEPLOYMENT_TARGET: "26.0"
      SWIFT_STRICT_CONCURRENCY: complete
      OTHER_LDFLAGS: ["-lc++"]
  targets:
    SynologyPhotos:
      type: application
      platform: macOS
      sources:
        - path: SynologyPhotos
        - path: ../bindings/PhotosCore.swift
          group: Generated
      dependencies:
        - framework: ../PhotosCore.xcframework
          embed: true
      settings:
        base:
          PRODUCT_BUNDLE_IDENTIFIER: com.sahil.synologyphotos
          GENERATE_INFOPLIST_FILE: YES
          INFOPLIST_KEY_NSHumanReadableCopyright: ""
          SWIFT_INCLUDE_PATHS: ["$(SRCROOT)/../bindings"]
          ENABLE_HARDENED_RUNTIME: YES
    SynologyPhotosTests:
      type: bundle.unit-test
      platform: macOS
      sources:
        - path: SynologyPhotosTests
      dependencies:
        - target: SynologyPhotos
      settings:
        base:
          SWIFT_INCLUDE_PATHS: ["$(SRCROOT)/../bindings"]
    SynologyPhotosUITests:
      type: bundle.ui-testing
      platform: macOS
      sources:
        - path: SynologyPhotosUITests
      dependencies:
        - target: SynologyPhotos
  schemes:
    SynologyPhotos:
      build:
        targets:
          SynologyPhotos: all
          SynologyPhotosTests: [test]
          SynologyPhotosUITests: [test]
      test:
        targets:
          - SynologyPhotosTests
          - SynologyPhotosUITests
  ```
  Create `app/SynologyPhotos/SynologyPhotosApp.swift`:
  ```swift
  import SwiftUI
  import PhotosCore

  @main
  struct SynologyPhotosApp: App {
      var body: some Scene {
          WindowGroup { ContentView() }
      }
  }

  struct ContentView: View {
      var body: some View {
          VStack {
              Text("Synology Photos").font(.title)
              Text("core \(coreVersion())").font(.caption).foregroundStyle(.secondary)
          }
          .padding()
          .frame(minWidth: 480, minHeight: 320)
      }
  }
  ```
  Create `app/SynologyPhotos/Resources/Assets.xcassets/Contents.json`:
  ```json
  { "info" : { "author" : "xcode", "version" : 1 } }
  ```
  Also create the UI-test target directory placeholder so xcodegen has sources (the real UI tests land in Task 54): create `app/SynologyPhotosUITests/.gitkeep`. Then build the xcframework if missing and generate the project:
  ```
  cd /Users/sahil/code/github/synology-native-photos && test -d PhotosCore.xcframework || make xcframework
  cd /Users/sahil/code/github/synology-native-photos/app && xcodegen generate
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild build -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS,arch=arm64' 2>&1 | tail -8
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/CoreBridgeSmokeTests 2>&1 | tail -12
  ```
  Expected: `** BUILD SUCCEEDED **`; then `Test Suite 'CoreBridgeSmokeTests' passed`, 2 tests passed.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add app/project.yml app/SynologyPhotos/ app/SynologyPhotosTests/CoreBridgeSmokeTests.swift app/SynologyPhotosUITests/.gitkeep app/SynologyPhotos.xcodeproj
  git commit -m "Create SwiftUI app project, link the core framework, and prove the FFI boundary"
  ```

---

### Task 9: Empirical NAS probe, capture real `SYNO.API.Info query=all` output

**Files**
- Modify: `documentation/phase0-probe-results.md` (append the API.Info section)

**Interfaces**
- Consumes: the dedicated Photos user and probe-results file from Task 3.
- Produces: a recorded, verbatim capture of the real `SYNO.API.Info` capability map: exact API names, cgi paths, and min/max versions actually advertised. This is the ground truth against which Task 17 (`info.rs`) and every version-pinned call is validated. If the real names differ from the contract, escalate to amend the contract rather than forking.

**Steps** (human-run against the real NAS; this is a documentation probe, not a compiled test)

- [ ] Verify the section is absent (failing pre-state):
  ```
  grep -q "## Probe: SYNO.API.Info" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `ABSENT`.
- [ ] Capture the real output (LAN, dedicated user session):
  ```
  curl -sk "https://<HOST>:5001/photo/webapi/query.cgi?api=SYNO.API.Info&version=1&method=query&query=all" | tee /tmp/syno-info.json | python3 -m json.tool | head -80
  ```
- [ ] Append a `## Probe: SYNO.API.Info` section to `documentation/phase0-probe-results.md` recording, verbatim: the cgi path used, whether `success` was true, and a table of the APIs the app relies on with their advertised `path`, `minVersion`, `maxVersion`:

  | API | path | minVersion | maxVersion |
  |-----|------|------------|------------|
  | SYNO.API.Auth | (record) | (record) | (record) |
  | SYNO.API.Info | (record) | (record) | (record) |
  | SYNO.Foto.Browse.Item | (record) | (record) | (record) |
  | SYNO.Foto.Browse.Album | (record) | (record) | (record) |
  | SYNO.Foto.Thumbnail | (record) | (record) | (record) |
  | SYNO.Foto.Download | (record) | (record) | (record) |
  | SYNO.FotoTeam.Browse.Item | (record) | (record) | (record) |
  | SYNO.FotoTeam.Browse.Album | (record) | (record) | (record) |
  | SYNO.FotoTeam.Thumbnail | (record) | (record) | (record) |
  | SYNO.FotoTeam.Download | (record) | (record) | (record) |

  Note any API present under a different name, or absent, and flag it for a contract amendment.
- [ ] Verify:
  ```
  grep -q "## Probe: SYNO.API.Info" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record real SYNO.API.Info capability map from the NAS"
  ```

---

### Task 10: Empirical NAS probe, real login incl. 2FA/OTP round trip

**Files**
- Modify: `documentation/phase0-probe-results.md` (append the login/2FA section)

**Interfaces**
- Consumes: the dedicated Photos user (Task 3), the API.Info capture (Task 9).
- Produces: verbatim record of the auth.cgi path, param names (`account`, `passwd`, `otp_code`, `format`, `enable_syno_token`), the OTP error codes the real DSM returns when 2FA is needed vs when the code is wrong, whether `SynoToken` is returned, and the `did` "remember device" field. Ground truth for Task 16 (`auth.rs`).

**Steps** (human-run)

- [ ] Verify absent:
  ```
  grep -q "## Probe: Login and 2FA" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `ABSENT`.
- [ ] Capture a login WITHOUT otp (expect a 2FA-needed error), then WITH otp:
  ```
  curl -sk "https://<HOST>:5001/photo/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=photosclient&passwd=<PW>&format=sid&enable_syno_token=yes"
  curl -sk "https://<HOST>:5001/photo/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=photosclient&passwd=<PW>&format=sid&enable_syno_token=yes&otp_code=<CODE>"
  ```
- [ ] Append a `## Probe: Login and 2FA` section recording, verbatim: the exact error.code returned when otp is missing (contract assumes 403 => OtpRequired), the error.code when otp is wrong (contract assumes 404 => OtpRequired), the error.code for bad password (contract assumes 400 => Auth), the returned `sid`/`synotoken`/`did` field names, and whether the token header on later calls is `X-SYNO-TOKEN`. Flag any deviation from the contract mapping (contract section 2.2) for amendment.
- [ ] Verify:
  ```
  grep -q "## Probe: Login and 2FA" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record real login and 2FA round trip against the NAS"
  ```

---

### Task 11: Empirical NAS probe, Browse.Item + Thumbnail + Download response shapes

**Files**
- Modify: `documentation/phase0-probe-results.md` (append the browse/media section)

**Interfaces**
- Consumes: a valid SID + SynoToken (Task 10), the capability versions (Task 9).
- Produces: verbatim field names for a Browse.Item list row (`id`, `filename`, `type`, `time`, `filesize`, `additional.thumbnail.cache_key`, `additional.resolution.{width,height}`, `version`), the Thumbnail `get` param names and size tokens (`sm`/`m`/`xl`), and the Download `download` param names (`unit_id`, `cache_key`) and error envelope. Ground truth for Tasks 18, 19, 20.

**Steps** (human-run)

- [ ] Verify absent:
  ```
  grep -q "## Probe: Browse, Thumbnail, Download" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `ABSENT`.
- [ ] Capture a list page and one thumbnail/download:
  ```
  curl -sk "https://<HOST>:5001/photo/webapi/entry.cgi?api=SYNO.Foto.Browse.Item&version=1&method=list&offset=0&limit=5&additional=[\"thumbnail\",\"resolution\"]&_sid=<SID>" | python3 -m json.tool | head -80
  curl -sk -o /tmp/thumb.jpg "https://<HOST>:5001/photo/webapi/entry.cgi?api=SYNO.Foto.Thumbnail&version=2&method=get&id=<ID>&cache_key=<CK>&type=unit&size=sm&_sid=<SID>"; file /tmp/thumb.jpg
  curl -sk -o /tmp/orig "https://<HOST>:5001/photo/webapi/entry.cgi?api=SYNO.Foto.Download&version=2&method=download&unit_id=[<ID>]&cache_key=<CK>&_sid=<SID>"; file /tmp/orig
  ```
- [ ] Append a `## Probe: Browse, Thumbnail, Download` section recording the verbatim JSON field paths for one item, the actual size tokens accepted by Thumbnail, the actual Download param names, and any deviation from the contract field names in Task 18's `RawItem` mapping. Flag deviations for amendment.
- [ ] Verify:
  ```
  grep -q "## Probe: Browse, Thumbnail, Download" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record real browse, thumbnail and download response shapes"
  ```

---

### Task 12: Empirical NAS probe, capture the DSM self-signed cert DER over LAN and Tailscale, document the pinning decision

**Files**
- Modify: `documentation/phase0-probe-results.md` (append the cert/TLS section)
- Create: `documentation/nas-cert.der` is NOT committed (it is host-specific trust material); record only its SHA-256 and capture command in the doc.

**Interfaces**
- Consumes: reachability to the NAS over LAN and over the Tailscale name.
- Produces: the documented procedure to capture the cert DER, its SHA-256 fingerprint, and the recorded decision that the Tailscale name (whose CN will not match) is trusted ONLY via `pinned_cert_der` with hostname verification left on (contract section 2.6). Ground truth for Task 15 (`transport.rs`) and Tasks 41/42 (Tailscale verification).

**Steps** (human-run)

- [ ] Verify absent:
  ```
  grep -q "## Probe: TLS cert and pinning decision" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `ABSENT`.
- [ ] Capture the DER over LAN and print its fingerprint:
  ```
  openssl s_client -connect <LAN_IP>:5001 -showcerts </dev/null 2>/dev/null | openssl x509 -outform DER -out /tmp/nas-lan.der
  openssl x509 -inform DER -in /tmp/nas-lan.der -noout -sha256 -fingerprint -subject -issuer
  openssl s_client -connect <TAILSCALE_NAME>:5001 -servername <TAILSCALE_NAME> -showcerts </dev/null 2>/dev/null | openssl x509 -outform DER -out /tmp/nas-ts.der
  openssl x509 -inform DER -in /tmp/nas-ts.der -noout -sha256 -fingerprint -subject
  ```
- [ ] Append a `## Probe: TLS cert and pinning decision` section recording: whether the LAN and Tailscale endpoints present the same cert, the SHA-256 fingerprint, the cert subject CN, and the decision text: "LAN uses system trust (no auto-pin). The Tailscale name mismatches the cert CN, so it is trusted only by pinning this exact DER via reqwest add_root_certificate with hostname verification left on. danger_accept_invalid_certs is never used." Note where the DER file is stored locally (developer machine, not the repo).
- [ ] Verify:
  ```
  grep -q "## Probe: TLS cert and pinning decision" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record NAS TLS cert fingerprint and cert-pinning decision"
  ```

---

### Task 13: Empirical DELETE-semantics probe on a throwaway asset (documented, no code)

**Files**
- Modify: `documentation/phase0-probe-results.md` (fill the delete-semantics verdict table created in Task 3)

**Interfaces**
- Consumes: the delete-semantics procedure and empty verdict table from Task 3; a valid SID/SynoToken (Task 10); a throwaway asset id/unit_id/cache_key (Task 11).
- Produces: the filled verdict table characterizing whether delete is trash-move or permanent. NO delete code is added to any crate. This closes the design's Phase 0 empirical-delete-probe item.

**Steps** (human-run against the real NAS, throwaway asset only)

- [ ] Verify the verdict table still shows `pending` (failing pre-state):
  ```
  grep -q "| Date probed | pending |" documentation/phase0-probe-results.md && echo PENDING || echo FILLED
  ```
  Expected: `PENDING`.
- [ ] Run the procedure documented in Task 3 (list, observe trash state, issue delete on the throwaway, re-check state, probe permanent-delete if a trash location holds it). Record every response verbatim.
- [ ] Fill the verdict table rows in `documentation/phase0-probe-results.md` with the observed values, ending with the `Verdict: trash-move then gated permanent-delete confirmed?` row.
- [ ] Verify:
  ```
  grep -q "| Date probed | pending |" documentation/phase0-probe-results.md && echo PENDING || echo FILLED
  ```
  Expected: `FILLED`.
- [ ] Confirm no delete code leaked into the core:
  ```
  grep -rn "method=delete\|fn delete" core/ 2>/dev/null; echo "core-delete-refs-exit=$?"
  ```
  Expected: no matches in non-test core source.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record delete-semantics probe verdict from throwaway asset"
  ```

---

## Phase 1: Read-only browse MVP

After Task 8, three streams parallelize: the `synology-api` crate (Tasks 14 through 24), the `persistence` + `sync-engine` crates (Tasks 25 through 32), and the Swift app (Tasks 33 through 45). The `synology-api` and persistence/sync work touch disjoint crates and never the same file. The facade-wiring tasks (Tasks 33 through 38) depend on both crate APIs being frozen by this plan, so they may stub against the signatures immediately and swap in the real crates as they land. The Swift app depends only on `bindings/PhotosCore.swift` (frozen by Task 7) through a protocol mock until Task 38 delivers the real xcframework.

### Task 14: Add dependencies to the `synology-api` crate

**Files**
- Modify: `core/synology-api/Cargo.toml`
- Create: `core/synology-api/src/lib.rs` (initial `VERSION` marker)
- Create: `core/synology-api/tests/deps_smoke.rs`

**Interfaces**
- Consumes: the `models` crate (path dep, Task 5).
- Produces: a compiling crate with `reqwest` (rustls-tls), `serde`, `serde_json`, `tokio`, `thiserror`, `tracing`, and dev-deps `mockito`, tokio test macros. `pub const VERSION: &str`.

**TDD steps**

- [ ] Write the failing test. Set `core/synology-api/src/lib.rs` to `pub const VERSION: &str = env!("CARGO_PKG_VERSION");` and create `core/synology-api/tests/deps_smoke.rs`:
  ```rust
  #[test]
  fn crate_builds_with_deps() {
      let _client = reqwest::Client::builder()
          .use_rustls_tls()
          .build()
          .expect("rustls client builds");
      assert!(!synology_api::VERSION.is_empty());
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api --test deps_smoke
  ```
  Expected: compile error `use of undeclared crate reqwest` (deps not yet declared).
- [ ] Minimal implementation. Set `core/synology-api/Cargo.toml`:
  ```toml
  [package]
  name = "synology-api"
  edition.workspace = true
  version.workspace = true
  license.workspace = true

  [dependencies]
  models = { path = "../models" }
  reqwest.workspace = true
  serde.workspace = true
  serde_json.workspace = true
  tokio.workspace = true
  thiserror.workspace = true
  tracing.workspace = true

  [dev-dependencies]
  mockito = "1"
  tokio = { version = "1", features = ["rt-multi-thread", "macros", "time", "test-util"] }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api --test deps_smoke
  ```
  Expected: `test crate_builds_with_deps ... ok`, `1 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/Cargo.toml core/synology-api/src/lib.rs core/synology-api/tests/deps_smoke.rs
  git commit -m "Set up synology-api crate dependencies with rustls transport"
  ```

---

### Task 15: Space to namespace resolver (`namespace.rs`)

**Files**
- Create: `core/synology-api/src/namespace.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod namespace;`)

**Interfaces**
- Consumes: `models::Space`.
- Produces: `pub fn browse_item_api(space: Space) -> &'static str`, `pub fn browse_album_api(space: Space) -> &'static str`, `pub fn thumbnail_api(space: Space) -> &'static str`, `pub fn download_api(space: Space) -> &'static str`. Personal => `SYNO.Foto.*`; Shared => `SYNO.FotoTeam.*`.

**TDD steps**

- [ ] Write the failing test in `core/synology-api/src/namespace.rs`:
  ```rust
  use models::Space;

  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn personal_maps_to_foto() {
          assert_eq!(browse_item_api(Space::Personal), "SYNO.Foto.Browse.Item");
          assert_eq!(browse_album_api(Space::Personal), "SYNO.Foto.Browse.Album");
          assert_eq!(thumbnail_api(Space::Personal), "SYNO.Foto.Thumbnail");
          assert_eq!(download_api(Space::Personal), "SYNO.Foto.Download");
      }

      #[test]
      fn shared_maps_to_fototeam() {
          assert_eq!(browse_item_api(Space::Shared), "SYNO.FotoTeam.Browse.Item");
          assert_eq!(browse_album_api(Space::Shared), "SYNO.FotoTeam.Browse.Album");
          assert_eq!(thumbnail_api(Space::Shared), "SYNO.FotoTeam.Thumbnail");
          assert_eq!(download_api(Space::Shared), "SYNO.FotoTeam.Download");
      }
  }
  ```
  Add `pub mod namespace;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api namespace
  ```
  Expected: compile error `cannot find function browse_item_api in this scope`.
- [ ] Minimal implementation. Prepend to `core/synology-api/src/namespace.rs` (above the test block; keep the single top-level `use models::Space;`):
  ```rust
  use models::Space;

  pub fn browse_item_api(space: Space) -> &'static str {
      match space {
          Space::Personal => "SYNO.Foto.Browse.Item",
          Space::Shared => "SYNO.FotoTeam.Browse.Item",
      }
  }

  pub fn browse_album_api(space: Space) -> &'static str {
      match space {
          Space::Personal => "SYNO.Foto.Browse.Album",
          Space::Shared => "SYNO.FotoTeam.Browse.Album",
      }
  }

  pub fn thumbnail_api(space: Space) -> &'static str {
      match space {
          Space::Personal => "SYNO.Foto.Thumbnail",
          Space::Shared => "SYNO.FotoTeam.Thumbnail",
      }
  }

  pub fn download_api(space: Space) -> &'static str {
      match space {
          Space::Personal => "SYNO.Foto.Download",
          Space::Shared => "SYNO.FotoTeam.Download",
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api namespace
  ```
  Expected: `2 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/namespace.rs core/synology-api/src/lib.rs
  git commit -m "Add Space to Synology API namespace resolver for Personal and Shared"
  ```

---

### Task 16: Tolerant envelope decode (`envelope.rs`) with unknown-field proof

**Files**
- Create: `core/synology-api/src/envelope.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod envelope;`)

**Interfaces**
- Consumes: `models::CoreError`, `serde`, `serde_json`.
- Produces: `pub struct SynoResponse<T>` (`success`, `data: Option<T>`, `error: Option<SynoError>`), `pub struct SynoError { pub code: i64 }`, `pub fn decode_envelope<T: DeserializeOwned>(body: &str) -> Result<T, CoreError>`, `pub fn map_error_code(code: i64) -> CoreError`. Mapping (contract 2.2): 400/401 => `Auth`, 403/404 => `OtpRequired`, unknown => `UnexpectedResponse` (fail closed); serde failure => `Decode`; `success:true` with missing `data` => `UnexpectedResponse`.

**TDD steps**

- [ ] Write the failing test in `core/synology-api/src/envelope.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use models::CoreError;
      use serde::Deserialize;

      #[derive(Debug, Deserialize, PartialEq)]
      struct Known { id: i64, name: String }

      #[test]
      fn decodes_success_ignoring_unknown_fields() {
          let body = r#"{ "success": true, "data": { "id": 7, "name": "beach", "extra_meta": {"x": 1}, "future_flag": true } }"#;
          let got: Known = decode_envelope(body).expect("unknown fields must not break decode");
          assert_eq!(got, Known { id: 7, name: "beach".into() });
      }

      #[test]
      fn success_false_400_maps_to_auth() {
          let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 400 } }"#).unwrap_err();
          assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
      }

      #[test]
      fn success_false_403_maps_to_otp_required() {
          let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 403 } }"#).unwrap_err();
          assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");
      }

      #[test]
      fn success_false_404_maps_to_otp_required() {
          let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 404 } }"#).unwrap_err();
          assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");
      }

      #[test]
      fn success_false_unknown_code_fails_closed_unexpected() {
          let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 9999 } }"#).unwrap_err();
          assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
      }

      #[test]
      fn garbage_body_maps_to_decode() {
          let err = decode_envelope::<Known>("not json at all").unwrap_err();
          assert!(matches!(err, CoreError::Decode { .. }), "got {err:?}");
      }

      #[test]
      fn success_true_missing_data_fails_closed() {
          let err = decode_envelope::<Known>(r#"{ "success": true }"#).unwrap_err();
          assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
      }
  }
  ```
  Add `pub mod envelope;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api envelope
  ```
  Expected: compile error `cannot find function decode_envelope in this scope`.
- [ ] Minimal implementation. Prepend to `core/synology-api/src/envelope.rs`:
  ```rust
  use models::CoreError;
  use serde::de::DeserializeOwned;
  use serde::Deserialize;

  #[derive(Debug, Deserialize)]
  pub struct SynoResponse<T> {
      #[serde(default)]
      pub success: bool,
      #[serde(default = "none")]
      pub data: Option<T>,
      #[serde(default = "none")]
      pub error: Option<SynoError>,
  }

  fn none<T>() -> Option<T> { None }

  #[derive(Debug, Deserialize)]
  pub struct SynoError {
      pub code: i64,
  }

  /// Map a Synology error.code to a CoreError per the authoritative contract.
  /// FAIL CLOSED: any code we do not explicitly recognize becomes UnexpectedResponse.
  pub fn map_error_code(code: i64) -> CoreError {
      match code {
          400 | 401 => CoreError::Auth { message: format!("synology auth error code {code}") },
          403 | 404 => CoreError::OtpRequired,
          other => CoreError::UnexpectedResponse { message: format!("unhandled synology error code {other}") },
      }
  }

  /// Tolerant decode: unknown fields inside T are ignored (we never use
  /// deny_unknown_fields). success:false => mapped error. Missing data on
  /// success:true => fail closed. Serde failure => Decode.
  pub fn decode_envelope<T: DeserializeOwned>(body: &str) -> Result<T, CoreError> {
      let parsed: SynoResponse<T> = serde_json::from_str(body).map_err(|e| CoreError::Decode {
          message: format!("envelope parse failed: {e}"),
      })?;
      if parsed.success {
          parsed.data.ok_or_else(|| CoreError::UnexpectedResponse {
              message: "success=true but data field missing".to_string(),
          })
      } else {
          let code = parsed.error.map(|e| e.code).unwrap_or(-1);
          Err(map_error_code(code))
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api envelope
  ```
  Expected: `7 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/envelope.rs core/synology-api/src/lib.rs
  git commit -m "Add tolerant Synology response envelope decode with fail-closed error mapping"
  ```

---

### Task 17: Transport with deliberate TLS trust and client-side throttle (`transport.rs`)

**Files**
- Create: `core/synology-api/src/transport.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod transport;`)

**Interfaces**
- Consumes: `models::{Connection, CoreError}`, `reqwest`.
- Produces: `pub fn build_client(connection: &Connection) -> Result<reqwest::Client, CoreError>` (system roots when `pinned_cert_der` is None; when `Some(der)`, `.add_root_certificate(cert)` + `.danger_accept_invalid_hostnames(false)`; never `danger_accept_invalid_certs`); `pub struct Transport` with `new(&Connection) -> Result<Self, CoreError>`, `base_url() -> &str`, `client() -> &reqwest::Client`, `async fn throttle(&self)` enforcing a 150ms minimum inter-request gap.

**TDD steps**

- [ ] Write the failing test in `core/synology-api/src/transport.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use models::Connection;

      fn conn(host: &str, pinned: Option<Vec<u8>>) -> Connection {
          Connection { host: host.to_string(), verify_tls: true, pinned_cert_der: pinned }
      }

      #[test]
      fn builds_client_with_system_roots_when_no_pin() {
          assert!(build_client(&conn("https://192.168.1.10:5001", None)).is_ok());
      }

      #[test]
      fn rejects_bad_pinned_cert() {
          let err = build_client(&conn("https://nas.ts.net:5001", Some(vec![0x00, 0x01, 0x02]))).unwrap_err();
          assert!(matches!(err, models::CoreError::Network { .. }), "got {err:?}");
      }

      #[test]
      fn transport_exposes_base_url() {
          let t = Transport::new(&conn("https://192.168.1.10:5001", None)).expect("transport builds");
          assert_eq!(t.base_url(), "https://192.168.1.10:5001");
      }

      #[tokio::test]
      async fn throttle_enforces_minimum_gap() {
          let t = Transport::new(&conn("https://192.168.1.10:5001", None)).expect("transport builds");
          let start = std::time::Instant::now();
          t.throttle().await;
          t.throttle().await;
          assert!(start.elapsed() >= std::time::Duration::from_millis(140),
                  "second throttle should enforce the inter-request gap");
      }
  }
  ```
  Add `pub mod transport;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api transport
  ```
  Expected: compile error `cannot find function build_client`.
- [ ] Minimal implementation. Prepend to `core/synology-api/src/transport.rs`:
  ```rust
  use models::{Connection, CoreError};
  use std::sync::Mutex;
  use std::time::{Duration, Instant};

  const MIN_REQUEST_GAP: Duration = Duration::from_millis(150);

  /// Build a reqwest client honoring the locked TLS trust contract (section 2.6).
  /// - No pinned cert: system roots, standard verification.
  /// - Pinned cert: trust exactly that DER, keep hostname verification ON.
  /// - danger_accept_invalid_certs is NEVER used.
  pub fn build_client(connection: &Connection) -> Result<reqwest::Client, CoreError> {
      let mut builder = reqwest::Client::builder()
          .use_rustls_tls()
          .timeout(Duration::from_secs(30))
          .connect_timeout(Duration::from_secs(10));
      if let Some(der) = &connection.pinned_cert_der {
          let cert = reqwest::Certificate::from_der(der).map_err(|e| CoreError::Network {
              message: format!("pinned certificate is not valid DER: {e}"),
          })?;
          builder = builder.add_root_certificate(cert).danger_accept_invalid_hostnames(false);
      }
      builder.build().map_err(|e| CoreError::Network {
          message: format!("failed to build HTTP client: {e}"),
      })
  }

  pub struct Transport {
      client: reqwest::Client,
      base_url: String,
      last_request: Mutex<Option<Instant>>,
  }

  impl Transport {
      pub fn new(connection: &Connection) -> Result<Self, CoreError> {
          let client = build_client(connection)?;
          Ok(Self {
              client,
              base_url: connection.host.trim_end_matches('/').to_string(),
              last_request: Mutex::new(None),
          })
      }

      pub fn base_url(&self) -> &str { &self.base_url }
      pub fn client(&self) -> &reqwest::Client { &self.client }

      /// Enforce a minimum gap between outbound requests (rate limits are undocumented).
      pub async fn throttle(&self) {
          let wait = {
              let mut guard = self.last_request.lock().expect("throttle mutex poisoned");
              let now = Instant::now();
              let wait = match *guard {
                  Some(prev) => {
                      let elapsed = now.duration_since(prev);
                      if elapsed < MIN_REQUEST_GAP { MIN_REQUEST_GAP - elapsed } else { Duration::ZERO }
                  }
                  None => Duration::ZERO,
              };
              *guard = Some(now + wait);
              wait
          };
          if !wait.is_zero() {
              tokio::time::sleep(wait).await;
          }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api transport
  ```
  Expected: `4 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/transport.rs core/synology-api/src/lib.rs
  git commit -m "Add HTTP transport with pinned-cert TLS trust and client-side throttle"
  ```

---

### Task 18: Auth login with 2FA/OTP and logout (`auth.rs`)

**Files**
- Create: `core/synology-api/src/auth.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod auth;`)
- Create: `core/synology-api/tests/auth_mock.rs`

**Interfaces**
- Consumes: `Transport` (Task 17), `decode_envelope` (Task 16), `models::{Session, CoreError}`.
- Produces: `pub async fn login(transport: &Transport, username: &str, password: &str, otp_code: Option<&str>) -> Result<Session, CoreError>` (calls `SYNO.API.Auth` v3 `method=login` at `/photo/webapi/auth.cgi`; sends `otp_code` only when `Some`; parses `sid` + optional `synotoken`/`did`; 403 => `OtpRequired`, 400 => `Auth`); `pub async fn logout(transport: &Transport, sid: &str) -> Result<(), CoreError>` (idempotent; a 400 is treated as already-logged-out).

**TDD steps**

- [ ] Write the failing test `core/synology-api/tests/auth_mock.rs`:
  ```rust
  use mockito::Matcher;
  use models::Connection;
  use synology_api::auth::{login, logout};
  use synology_api::transport::Transport;

  fn transport_for(server: &mockito::ServerGuard) -> Transport {
      Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
          .expect("transport builds")
  }

  #[tokio::test]
  async fn login_success_returns_session_with_sid_and_token() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/auth.cgi")
          .match_query(Matcher::AllOf(vec![
              Matcher::UrlEncoded("api".into(), "SYNO.API.Auth".into()),
              Matcher::UrlEncoded("method".into(), "login".into()),
              Matcher::UrlEncoded("account".into(), "photouser".into()),
          ]))
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"sid":"ABC123","synotoken":"TKN9","did":"DEV1","extra":"ignored"}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let session = login(&t, "photouser", "pw", None).await.expect("login ok");
      assert_eq!(session.sid, "ABC123");
      assert_eq!(session.syno_token.as_deref(), Some("TKN9"));
      assert_eq!(session.device_did.as_deref(), Some("DEV1"));
      assert_eq!(session.username, "photouser");
  }

  #[tokio::test]
  async fn login_without_otp_when_2fa_required_returns_otp_required() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/auth.cgi")
          .match_query(Matcher::Missing("otp_code".into()))
          .with_status(200)
          .with_body(r#"{"success":false,"error":{"code":403}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let err = login(&t, "photouser", "pw", None).await.unwrap_err();
      assert!(matches!(err, models::CoreError::OtpRequired), "got {err:?}");
  }

  #[tokio::test]
  async fn login_with_otp_code_succeeds() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/auth.cgi")
          .match_query(Matcher::UrlEncoded("otp_code".into(), "654321".into()))
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"sid":"OTPSID"}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let session = login(&t, "photouser", "pw", Some("654321")).await.expect("otp login ok");
      assert_eq!(session.sid, "OTPSID");
      assert_eq!(session.syno_token, None);
      assert_eq!(session.device_did, None);
  }

  #[tokio::test]
  async fn login_bad_credentials_maps_to_auth() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/auth.cgi")
          .with_status(200)
          .with_body(r#"{"success":false,"error":{"code":400}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let err = login(&t, "photouser", "wrong", None).await.unwrap_err();
      assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
  }

  #[tokio::test]
  async fn logout_is_idempotent_on_400() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/auth.cgi")
          .match_query(Matcher::UrlEncoded("method".into(), "logout".into()))
          .with_status(200)
          .with_body(r#"{"success":false,"error":{"code":400}}"#)
          .create_async().await;
      let t = transport_for(&server);
      logout(&t, "ABC123").await.expect("logout treats 400 as already-out");
  }
  ```
  Add `pub mod auth;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api --test auth_mock
  ```
  Expected: compile error `unresolved import synology_api::auth::login`.
- [ ] Minimal implementation. Create `core/synology-api/src/auth.rs`:
  ```rust
  use crate::envelope::decode_envelope;
  use crate::transport::Transport;
  use models::{CoreError, Session};
  use serde::Deserialize;

  const AUTH_PATH: &str = "/photo/webapi/auth.cgi";
  const AUTH_API: &str = "SYNO.API.Auth";
  const AUTH_VERSION: &str = "3";

  #[derive(Debug, Deserialize)]
  struct LoginData {
      sid: String,
      #[serde(default)]
      synotoken: Option<String>,
      #[serde(default)]
      did: Option<String>,
  }

  /// Log in via SYNO.API.Auth. otp_code sent only when Some. Unknown response fields ignored.
  pub async fn login(
      transport: &Transport,
      username: &str,
      password: &str,
      otp_code: Option<&str>,
  ) -> Result<Session, CoreError> {
      transport.throttle().await;
      let mut query: Vec<(&str, String)> = vec![
          ("api", AUTH_API.to_string()),
          ("version", AUTH_VERSION.to_string()),
          ("method", "login".to_string()),
          ("account", username.to_string()),
          ("passwd", password.to_string()),
          ("format", "sid".to_string()),
          ("enable_syno_token", "yes".to_string()),
      ];
      if let Some(code) = otp_code {
          query.push(("otp_code", code.to_string()));
      }
      let url = format!("{}{}", transport.base_url(), AUTH_PATH);
      let resp = transport.client().get(&url).query(&query).send().await
          .map_err(|e| CoreError::Network { message: format!("login request failed: {e}") })?;
      let body = resp.text().await.map_err(|e| CoreError::Network { message: format!("reading login body failed: {e}") })?;
      let data: LoginData = decode_envelope(&body)?;
      Ok(Session {
          sid: data.sid,
          syno_token: data.synotoken,
          username: username.to_string(),
          device_did: data.did,
      })
  }

  /// Log out. Idempotent: a 400 (no such session) is treated as already-logged-out.
  pub async fn logout(transport: &Transport, sid: &str) -> Result<(), CoreError> {
      transport.throttle().await;
      let query: Vec<(&str, String)> = vec![
          ("api", AUTH_API.to_string()),
          ("version", AUTH_VERSION.to_string()),
          ("method", "logout".to_string()),
          ("_sid", sid.to_string()),
      ];
      let url = format!("{}{}", transport.base_url(), AUTH_PATH);
      let resp = transport.client().get(&url).query(&query).send().await
          .map_err(|e| CoreError::Network { message: format!("logout request failed: {e}") })?;
      let body = resp.text().await.map_err(|e| CoreError::Network { message: format!("reading logout body failed: {e}") })?;
      match decode_envelope::<serde_json::Value>(&body) {
          Ok(_) => Ok(()),
          Err(CoreError::Auth { .. }) => Ok(()),
          Err(CoreError::UnexpectedResponse { .. }) => Ok(()),
          Err(other) => Err(other),
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api --test auth_mock
  ```
  Expected: `5 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/auth.rs core/synology-api/src/lib.rs core/synology-api/tests/auth_mock.rs
  git commit -m "Add SYNO.API.Auth login with OTP handling and idempotent logout"
  ```

---

### Task 19: Capability probe with version pinning (`info.rs`)

**Files**
- Create: `core/synology-api/src/info.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod info;`)
- Create: `core/synology-api/tests/info_mock.rs`

**Interfaces**
- Consumes: `Transport` (Task 17), `decode_envelope` (Task 16), `models::{ApiCapability, CoreError}`.
- Produces: `pub async fn probe_capabilities(transport: &Transport) -> Result<Vec<ApiCapability>, CoreError>` (calls `SYNO.API.Info method=query&query=all` at `/photo/webapi/query.cgi`; maps the `{ "SYNO.X": {"path","minVersion","maxVersion"} }` map into `Vec<ApiCapability>`); `pub fn pin_version(caps: &[ApiCapability], api: &str, desired: u32) -> Result<u32, CoreError>` (clamps into `[min,max]`; `CapabilityUnavailable` if absent).

**TDD steps**

- [ ] Write the failing test `core/synology-api/tests/info_mock.rs`:
  ```rust
  use models::{ApiCapability, Connection, CoreError};
  use synology_api::info::{pin_version, probe_capabilities};
  use synology_api::transport::Transport;

  fn transport_for(server: &mockito::ServerGuard) -> Transport {
      Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
          .expect("transport builds")
  }

  #[tokio::test]
  async fn probe_parses_capability_map() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/query.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{
              "SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7},
              "SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":4,"future":"ignored"}
          }}"#)
          .create_async().await;
      let t = transport_for(&server);
      let mut caps = probe_capabilities(&t).await.expect("probe ok");
      caps.sort_by(|a, b| a.name.cmp(&b.name));
      assert_eq!(caps.len(), 2);
      let item = caps.iter().find(|c| c.name == "SYNO.Foto.Browse.Item").unwrap();
      assert_eq!(item.path, "entry.cgi");
      assert_eq!(item.min_version, 1);
      assert_eq!(item.max_version, 4);
  }

  #[test]
  fn pin_version_clamps_into_range() {
      let caps = vec![ApiCapability {
          name: "SYNO.Foto.Browse.Item".into(), path: "entry.cgi".into(),
          min_version: 2, max_version: 4,
      }];
      assert_eq!(pin_version(&caps, "SYNO.Foto.Browse.Item", 3).unwrap(), 3);
      assert_eq!(pin_version(&caps, "SYNO.Foto.Browse.Item", 9).unwrap(), 4);
      assert_eq!(pin_version(&caps, "SYNO.Foto.Browse.Item", 1).unwrap(), 2);
  }

  #[test]
  fn pin_version_missing_api_is_capability_unavailable() {
      let caps: Vec<ApiCapability> = vec![];
      let err = pin_version(&caps, "SYNO.Foto.Thumbnail", 2).unwrap_err();
      assert!(matches!(err, CoreError::CapabilityUnavailable { ref api } if api == "SYNO.Foto.Thumbnail"), "got {err:?}");
  }
  ```
  Add `pub mod info;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api --test info_mock
  ```
  Expected: compile error `unresolved import synology_api::info`.
- [ ] Minimal implementation. Create `core/synology-api/src/info.rs`:
  ```rust
  use crate::envelope::decode_envelope;
  use crate::transport::Transport;
  use models::{ApiCapability, CoreError};
  use serde::Deserialize;
  use std::collections::HashMap;

  const INFO_PATH: &str = "/photo/webapi/query.cgi";
  const INFO_API: &str = "SYNO.API.Info";
  const INFO_VERSION: &str = "1";

  #[derive(Debug, Deserialize)]
  struct CapEntry {
      path: String,
      #[serde(rename = "minVersion")]
      min_version: u32,
      #[serde(rename = "maxVersion")]
      max_version: u32,
  }

  /// SYNO.API.Info query=all. Returns every advertised API with its version window.
  pub async fn probe_capabilities(transport: &Transport) -> Result<Vec<ApiCapability>, CoreError> {
      transport.throttle().await;
      let query: Vec<(&str, String)> = vec![
          ("api", INFO_API.to_string()),
          ("version", INFO_VERSION.to_string()),
          ("method", "query".to_string()),
          ("query", "all".to_string()),
      ];
      let url = format!("{}{}", transport.base_url(), INFO_PATH);
      let resp = transport.client().get(&url).query(&query).send().await
          .map_err(|e| CoreError::Network { message: format!("capability probe request failed: {e}") })?;
      let body = resp.text().await.map_err(|e| CoreError::Network { message: format!("reading capability body failed: {e}") })?;
      let map: HashMap<String, CapEntry> = decode_envelope(&body)?;
      Ok(map.into_iter().map(|(name, entry)| ApiCapability {
          name, path: entry.path, min_version: entry.min_version, max_version: entry.max_version,
      }).collect())
  }

  /// Clamp `desired` into the advertised [min,max] window for `api`.
  /// FAIL CLOSED: absent api => CapabilityUnavailable.
  pub fn pin_version(caps: &[ApiCapability], api: &str, desired: u32) -> Result<u32, CoreError> {
      let cap = caps.iter().find(|c| c.name == api)
          .ok_or_else(|| CoreError::CapabilityUnavailable { api: api.to_string() })?;
      Ok(desired.clamp(cap.min_version, cap.max_version))
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api --test info_mock
  ```
  Expected: `3 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/info.rs core/synology-api/src/lib.rs core/synology-api/tests/info_mock.rs
  git commit -m "Add SYNO.API.Info capability probe with version pinning"
  ```

---

### Task 20: Browse items and albums, space-aware (`browse.rs`)

**Files**
- Create: `core/synology-api/src/browse.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod browse;`)
- Create: `core/synology-api/tests/browse_mock.rs`

**Interfaces**
- Consumes: `Transport` (Task 17), `decode_envelope` (Task 16), `namespace::{browse_item_api, browse_album_api}` (Task 15), `models::{Space, MediaKind, Asset, Album, CoreError}`.
- Produces: `pub async fn list_items(transport: &Transport, sid: &str, space: Space, offset: u32, limit: u32, version: u32) -> Result<Vec<Asset>, CoreError>` and `pub async fn list_albums(transport: &Transport, sid: &str, space: Space, offset: u32, limit: u32, version: u32) -> Result<Vec<Album>, CoreError>`, both `method=list` at `/photo/webapi/entry.cgi`, api name from the space resolver, `additional=["thumbnail","resolution"]`; unknown item fields ignored; unrecognized media type => `MediaKind::Unknown`.

**TDD steps**

- [ ] Write the failing test `core/synology-api/tests/browse_mock.rs`:
  ```rust
  use models::{Connection, MediaKind, Space};
  use synology_api::browse::{list_albums, list_items};
  use synology_api::transport::Transport;

  fn transport_for(server: &mockito::ServerGuard) -> Transport {
      Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
          .expect("transport builds")
  }

  #[tokio::test]
  async fn list_items_personal_parses_assets_and_ignores_unknown_fields() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()))
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"list":[
              {"id":101,"filename":"a.jpg","type":"photo","time":1700000000,"filesize":2048,
               "additional":{"thumbnail":{"cache_key":"CK101"},"resolution":{"width":4000,"height":3000}},
               "unmodeled":"ignore me"},
              {"id":102,"filename":"b.mp4","type":"video","time":1700000100,
               "additional":{"thumbnail":{"cache_key":"CK102"}}}
          ]}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1).await.expect("list ok");
      assert_eq!(assets.len(), 2);
      let a = &assets[0];
      assert_eq!(a.id, 101);
      assert_eq!(a.cache_key, "CK101");
      assert_eq!(a.filename, "a.jpg");
      assert_eq!(a.media_kind, MediaKind::Photo);
      assert_eq!(a.taken_at, Some(1700000000));
      assert_eq!(a.width, Some(4000));
      assert_eq!(a.height, Some(3000));
      assert_eq!(a.file_size, Some(2048));
      assert_eq!(a.space, Space::Personal);
      let b = &assets[1];
      assert_eq!(b.media_kind, MediaKind::Video);
      assert_eq!(b.cache_key, "CK102");
      assert_eq!(b.width, None);
  }

  #[tokio::test]
  async fn list_items_shared_uses_fototeam_namespace() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.FotoTeam.Browse.Item".into()))
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"list":[]}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let assets = list_items(&t, "SID", Space::Shared, 0, 100, 1).await.expect("list ok");
      assert!(assets.is_empty());
  }

  #[tokio::test]
  async fn unknown_media_type_decodes_as_unknown_not_error() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"list":[
              {"id":9,"filename":"live.heic","type":"live_photo","additional":{"thumbnail":{"cache_key":"CK9"}}}
          ]}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1).await.expect("list ok");
      assert_eq!(assets[0].media_kind, MediaKind::Unknown);
  }

  #[tokio::test]
  async fn list_albums_parses_albums() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Album".into()))
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"list":[
              {"id":5,"name":"Trip","item_count":42,"additional":{"thumbnail":{"cache_key":"COVER5"}}}
          ]}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let albums = list_albums(&t, "SID", Space::Personal, 0, 100, 1).await.expect("albums ok");
      assert_eq!(albums.len(), 1);
      assert_eq!(albums[0].id, 5);
      assert_eq!(albums[0].name, "Trip");
      assert_eq!(albums[0].item_count, 42);
      assert_eq!(albums[0].cover_cache_key.as_deref(), Some("COVER5"));
      assert_eq!(albums[0].space, Space::Personal);
  }
  ```
  Add `pub mod browse;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api --test browse_mock
  ```
  Expected: compile error `unresolved import synology_api::browse`.
- [ ] Minimal implementation. Create `core/synology-api/src/browse.rs`:
  ```rust
  use crate::envelope::decode_envelope;
  use crate::namespace::{browse_album_api, browse_item_api};
  use crate::transport::Transport;
  use models::{Album, Asset, CoreError, MediaKind, Space};
  use serde::Deserialize;

  const ENTRY_PATH: &str = "/photo/webapi/entry.cgi";

  fn parse_media_kind(raw: &str) -> MediaKind {
      match raw {
          "photo" => MediaKind::Photo,
          "video" => MediaKind::Video,
          _ => MediaKind::Unknown,
      }
  }

  #[derive(Debug, Deserialize)]
  struct ItemList {
      #[serde(default)]
      list: Vec<RawItem>,
  }

  #[derive(Debug, Deserialize)]
  struct RawItem {
      id: i64,
      filename: String,
      #[serde(rename = "type", default)]
      kind: String,
      #[serde(default)]
      time: Option<i64>,
      #[serde(default)]
      create_time: Option<i64>,
      #[serde(default)]
      filesize: Option<u64>,
      #[serde(default)]
      version: Option<i64>,
      #[serde(default)]
      additional: Option<ItemAdditional>,
  }

  #[derive(Debug, Deserialize, Default)]
  struct ItemAdditional {
      #[serde(default)]
      thumbnail: Option<Thumb>,
      #[serde(default)]
      resolution: Option<Resolution>,
  }

  #[derive(Debug, Deserialize)]
  struct Thumb {
      #[serde(default)]
      cache_key: String,
  }

  #[derive(Debug, Deserialize)]
  struct Resolution {
      #[serde(default)]
      width: Option<u32>,
      #[serde(default)]
      height: Option<u32>,
  }

  #[derive(Debug, Deserialize)]
  struct AlbumList {
      #[serde(default)]
      list: Vec<RawAlbum>,
  }

  #[derive(Debug, Deserialize)]
  struct RawAlbum {
      id: i64,
      name: String,
      #[serde(default)]
      item_count: u32,
      #[serde(default)]
      additional: Option<ItemAdditional>,
  }

  async fn get_body(transport: &Transport, query: &[(&str, String)]) -> Result<String, CoreError> {
      transport.throttle().await;
      let url = format!("{}{}", transport.base_url(), ENTRY_PATH);
      let resp = transport.client().get(&url).query(query).send().await
          .map_err(|e| CoreError::Network { message: format!("browse request failed: {e}") })?;
      resp.text().await.map_err(|e| CoreError::Network { message: format!("reading browse body failed: {e}") })
  }

  /// SYNO.Foto(Team).Browse.Item method=list. space-aware. Ignores unknown item fields.
  pub async fn list_items(
      transport: &Transport,
      sid: &str,
      space: Space,
      offset: u32,
      limit: u32,
      version: u32,
  ) -> Result<Vec<Asset>, CoreError> {
      let query: Vec<(&str, String)> = vec![
          ("api", browse_item_api(space).to_string()),
          ("version", version.to_string()),
          ("method", "list".to_string()),
          ("offset", offset.to_string()),
          ("limit", limit.to_string()),
          ("additional", "[\"thumbnail\",\"resolution\"]".to_string()),
          ("_sid", sid.to_string()),
      ];
      let body = get_body(transport, &query).await?;
      let parsed: ItemList = decode_envelope(&body)?;
      Ok(parsed.list.into_iter().map(|it| {
          let add = it.additional.unwrap_or_default();
          let cache_key = add.thumbnail.map(|t| t.cache_key).unwrap_or_default();
          let (width, height) = match add.resolution {
              Some(r) => (r.width, r.height),
              None => (None, None),
          };
          Asset {
              id: it.id,
              cache_key,
              filename: it.filename,
              media_kind: parse_media_kind(&it.kind),
              taken_at: it.time,
              added_at: it.create_time,
              width,
              height,
              file_size: it.filesize,
              space,
              server_version: it.version,
          }
      }).collect())
  }

  /// SYNO.Foto(Team).Browse.Album method=list. space-aware.
  pub async fn list_albums(
      transport: &Transport,
      sid: &str,
      space: Space,
      offset: u32,
      limit: u32,
      version: u32,
  ) -> Result<Vec<Album>, CoreError> {
      let query: Vec<(&str, String)> = vec![
          ("api", browse_album_api(space).to_string()),
          ("version", version.to_string()),
          ("method", "list".to_string()),
          ("offset", offset.to_string()),
          ("limit", limit.to_string()),
          ("additional", "[\"thumbnail\"]".to_string()),
          ("_sid", sid.to_string()),
      ];
      let body = get_body(transport, &query).await?;
      let parsed: AlbumList = decode_envelope(&body)?;
      Ok(parsed.list.into_iter().map(|al| {
          let cover = al.additional.and_then(|a| a.thumbnail).map(|t| t.cache_key);
          Album {
              id: al.id,
              name: al.name,
              item_count: al.item_count,
              cover_cache_key: cover,
              space,
          }
      }).collect())
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api --test browse_mock
  ```
  Expected: `4 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/browse.rs core/synology-api/src/lib.rs core/synology-api/tests/browse_mock.rs
  git commit -m "Add space-aware Browse.Item and Browse.Album list decoding"
  ```

---

### Task 21: Thumbnail fetch (`thumbnail.rs`)

**Files**
- Create: `core/synology-api/src/thumbnail.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod thumbnail;`)
- Create: `core/synology-api/tests/thumbnail_mock.rs`

**Interfaces**
- Consumes: `Transport` (Task 17), `namespace::thumbnail_api` (Task 15), `map_error_code`/`SynoResponse`/`SynoError` (Task 16), `models::{Space, ThumbnailSize, CoreError}`.
- Produces: `pub fn size_param(size: ThumbnailSize) -> &'static str` (Sm=>"sm", M=>"m", Xl=>"xl"); `pub async fn fetch_thumbnail(transport: &Transport, sid: &str, space: Space, asset_id: i64, cache_key: &str, size: ThumbnailSize, version: u32) -> Result<Vec<u8>, CoreError>` (`method=get` at `/photo/webapi/entry.cgi`; binary body returned as-is; a JSON error envelope mapped via `map_error_code`).

**TDD steps**

- [ ] Write the failing test `core/synology-api/tests/thumbnail_mock.rs`:
  ```rust
  use models::{Connection, Space, ThumbnailSize};
  use synology_api::thumbnail::{fetch_thumbnail, size_param};
  use synology_api::transport::Transport;

  fn transport_for(server: &mockito::ServerGuard) -> Transport {
      Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
          .expect("transport builds")
  }

  #[test]
  fn size_param_maps_sizes() {
      assert_eq!(size_param(ThumbnailSize::Sm), "sm");
      assert_eq!(size_param(ThumbnailSize::M), "m");
      assert_eq!(size_param(ThumbnailSize::Xl), "xl");
  }

  #[tokio::test]
  async fn fetch_thumbnail_returns_binary_bytes() {
      let mut server = mockito::Server::new_async().await;
      let jpeg_magic = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .match_query(mockito::Matcher::AllOf(vec![
              mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
              mockito::Matcher::UrlEncoded("method".into(), "get".into()),
              mockito::Matcher::UrlEncoded("size".into(), "sm".into()),
          ]))
          .with_status(200)
          .with_header("content-type", "image/jpeg")
          .with_body(jpeg_magic.clone())
          .create_async().await;
      let t = transport_for(&server);
      let bytes = fetch_thumbnail(&t, "SID", Space::Personal, 101, "CK101", ThumbnailSize::Sm, 2).await.expect("thumb ok");
      assert_eq!(bytes, jpeg_magic);
  }

  #[tokio::test]
  async fn fetch_thumbnail_json_error_maps_to_core_error() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .with_status(200)
          .with_header("content-type", "application/json")
          .with_body(r#"{"success":false,"error":{"code":400}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let err = fetch_thumbnail(&t, "SID", Space::Personal, 101, "CK101", ThumbnailSize::Sm, 2).await.unwrap_err();
      assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
  }
  ```
  Add `pub mod thumbnail;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api --test thumbnail_mock
  ```
  Expected: compile error `unresolved import synology_api::thumbnail`.
- [ ] Minimal implementation. Create `core/synology-api/src/thumbnail.rs`:
  ```rust
  use crate::envelope::{map_error_code, SynoError, SynoResponse};
  use crate::namespace::thumbnail_api;
  use crate::transport::Transport;
  use models::{CoreError, Space, ThumbnailSize};

  const ENTRY_PATH: &str = "/photo/webapi/entry.cgi";

  pub fn size_param(size: ThumbnailSize) -> &'static str {
      match size {
          ThumbnailSize::Sm => "sm",
          ThumbnailSize::M => "m",
          ThumbnailSize::Xl => "xl",
      }
  }

  /// SYNO.Foto(Team).Thumbnail method=get. Returns image bytes.
  /// If the server answers with a JSON error envelope, that is mapped to a CoreError.
  pub async fn fetch_thumbnail(
      transport: &Transport,
      sid: &str,
      space: Space,
      asset_id: i64,
      cache_key: &str,
      size: ThumbnailSize,
      version: u32,
  ) -> Result<Vec<u8>, CoreError> {
      transport.throttle().await;
      let query: Vec<(&str, String)> = vec![
          ("api", thumbnail_api(space).to_string()),
          ("version", version.to_string()),
          ("method", "get".to_string()),
          ("id", asset_id.to_string()),
          ("cache_key", cache_key.to_string()),
          ("type", "unit".to_string()),
          ("size", size_param(size).to_string()),
          ("_sid", sid.to_string()),
      ];
      let url = format!("{}{}", transport.base_url(), ENTRY_PATH);
      let resp = transport.client().get(&url).query(&query).send().await
          .map_err(|e| CoreError::Network { message: format!("thumbnail request failed: {e}") })?;
      let is_json = resp.headers().get(reqwest::header::CONTENT_TYPE)
          .and_then(|v| v.to_str().ok())
          .map(|ct| ct.contains("application/json"))
          .unwrap_or(false);
      let bytes = resp.bytes().await.map_err(|e| CoreError::Network { message: format!("reading thumbnail body failed: {e}") })?;
      if is_json {
          let parsed: SynoResponse<serde_json::Value> = serde_json::from_slice(&bytes)
              .map_err(|e| CoreError::Decode { message: format!("thumbnail error envelope parse failed: {e}") })?;
          if parsed.success {
              return Err(CoreError::UnexpectedResponse { message: "thumbnail returned JSON success but no image bytes".to_string() });
          }
          let code = parsed.error.map(|e: SynoError| e.code).unwrap_or(-1);
          return Err(map_error_code(code));
      }
      Ok(bytes.to_vec())
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api --test thumbnail_mock
  ```
  Expected: `3 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/thumbnail.rs core/synology-api/src/lib.rs core/synology-api/tests/thumbnail_mock.rs
  git commit -m "Add space-aware thumbnail fetch with JSON error envelope handling"
  ```

---

### Task 22: Download original (`download.rs`)

**Files**
- Create: `core/synology-api/src/download.rs`
- Modify: `core/synology-api/src/lib.rs` (add `pub mod download;`)
- Create: `core/synology-api/tests/download_mock.rs`

**Interfaces**
- Consumes: `Transport` (Task 17), `namespace::download_api` (Task 15), `map_error_code`/`SynoResponse`/`SynoError` (Task 16), `models::{Space, CoreError}`.
- Produces: `pub async fn download_original(transport: &Transport, sid: &str, space: Space, unit_id: i64, cache_key: &str, version: u32) -> Result<Vec<u8>, CoreError>` (`method=download` at `/photo/webapi/entry.cgi`; returns original bytes; JSON error envelope mapped; READ-ONLY GET, never mutates).

**TDD steps**

- [ ] Write the failing test `core/synology-api/tests/download_mock.rs`:
  ```rust
  use models::{Connection, Space};
  use synology_api::download::download_original;
  use synology_api::transport::Transport;

  fn transport_for(server: &mockito::ServerGuard) -> Transport {
      Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
          .expect("transport builds")
  }

  #[tokio::test]
  async fn download_returns_original_bytes() {
      let mut server = mockito::Server::new_async().await;
      let payload = b"ORIGINAL-FILE-BYTES".to_vec();
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .match_query(mockito::Matcher::AllOf(vec![
              mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
              mockito::Matcher::UrlEncoded("method".into(), "download".into()),
          ]))
          .with_status(200)
          .with_header("content-type", "application/octet-stream")
          .with_body(payload.clone())
          .create_async().await;
      let t = transport_for(&server);
      let bytes = download_original(&t, "SID", Space::Personal, 101, "CK101", 2).await.expect("download ok");
      assert_eq!(bytes, payload);
  }

  #[tokio::test]
  async fn download_shared_uses_fototeam_namespace() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .match_query(mockito::Matcher::UrlEncoded("api".into(), "SYNO.FotoTeam.Download".into()))
          .with_status(200)
          .with_header("content-type", "application/octet-stream")
          .with_body(b"X".to_vec())
          .create_async().await;
      let t = transport_for(&server);
      let bytes = download_original(&t, "SID", Space::Shared, 7, "CK7", 2).await.expect("download ok");
      assert_eq!(bytes, b"X".to_vec());
  }

  #[tokio::test]
  async fn download_json_error_maps_to_core_error() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/entry.cgi")
          .with_status(200)
          .with_header("content-type", "application/json")
          .with_body(r#"{"success":false,"error":{"code":401}}"#)
          .create_async().await;
      let t = transport_for(&server);
      let err = download_original(&t, "SID", Space::Personal, 101, "CK101", 2).await.unwrap_err();
      assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
  }
  ```
  Add `pub mod download;` to `core/synology-api/src/lib.rs`.
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api --test download_mock
  ```
  Expected: compile error `unresolved import synology_api::download`.
- [ ] Minimal implementation. Create `core/synology-api/src/download.rs`:
  ```rust
  use crate::envelope::{map_error_code, SynoError, SynoResponse};
  use crate::namespace::download_api;
  use crate::transport::Transport;
  use models::{CoreError, Space};

  const ENTRY_PATH: &str = "/photo/webapi/entry.cgi";

  /// SYNO.Foto(Team).Download method=download. READ-ONLY: fetches original bytes, never mutates.
  /// A JSON error envelope (200 with application/json) is mapped and fails closed.
  pub async fn download_original(
      transport: &Transport,
      sid: &str,
      space: Space,
      unit_id: i64,
      cache_key: &str,
      version: u32,
  ) -> Result<Vec<u8>, CoreError> {
      transport.throttle().await;
      let query: Vec<(&str, String)> = vec![
          ("api", download_api(space).to_string()),
          ("version", version.to_string()),
          ("method", "download".to_string()),
          ("unit_id", format!("[{unit_id}]")),
          ("cache_key", cache_key.to_string()),
          ("_sid", sid.to_string()),
      ];
      let url = format!("{}{}", transport.base_url(), ENTRY_PATH);
      let resp = transport.client().get(&url).query(&query).send().await
          .map_err(|e| CoreError::Network { message: format!("download request failed: {e}") })?;
      let is_json = resp.headers().get(reqwest::header::CONTENT_TYPE)
          .and_then(|v| v.to_str().ok())
          .map(|ct| ct.contains("application/json"))
          .unwrap_or(false);
      let bytes = resp.bytes().await.map_err(|e| CoreError::Network { message: format!("reading download body failed: {e}") })?;
      if is_json {
          let parsed: SynoResponse<serde_json::Value> = serde_json::from_slice(&bytes)
              .map_err(|e| CoreError::Decode { message: format!("download error envelope parse failed: {e}") })?;
          if parsed.success {
              return Err(CoreError::UnexpectedResponse { message: "download returned JSON success but no file bytes".to_string() });
          }
          let code = parsed.error.map(|e: SynoError| e.code).unwrap_or(-1);
          return Err(map_error_code(code));
      }
      Ok(bytes.to_vec())
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api --test download_mock
  ```
  Expected: `3 passed`.
- [ ] Commit:
  ```
  git add core/synology-api/src/download.rs core/synology-api/src/lib.rs core/synology-api/tests/download_mock.rs
  git commit -m "Add read-only download of original media bytes, space-aware"
  ```

---

### Task 23: ApiClient facade re-exports, lib surface, and ignored real-NAS smoke test

**Files**
- Modify: `core/synology-api/src/lib.rs` (flat re-exports + inline `#[cfg(test)]`)
- Create: `core/synology-api/tests/real_nas_ignored.rs`

**Interfaces**
- Consumes: all modules from Tasks 15 through 22.
- Produces: the flat surface Author A imports (`use synology_api::...`): `pub use auth::{login, logout};`, `pub use info::{pin_version, probe_capabilities};`, `pub use browse::{list_albums, list_items};`, `pub use thumbnail::fetch_thumbnail;`, `pub use download::download_original;`, `pub use transport::{build_client, Transport};`, `pub use envelope::{decode_envelope, map_error_code, SynoError, SynoResponse};`. Plus an `#[ignore]`d env-driven integration test that must compile against the frozen facade.

**TDD steps**

- [ ] Write the failing test. Add to the bottom of `core/synology-api/src/lib.rs`:
  ```rust
  #[cfg(test)]
  mod facade_tests {
      #[test]
      fn reexports_are_reachable() {
          let _ = crate::login as usize;
          let _ = crate::logout as usize;
          let _ = crate::probe_capabilities as usize;
          let _ = crate::pin_version as usize;
          let _ = crate::list_items as usize;
          let _ = crate::list_albums as usize;
          let _ = crate::fetch_thumbnail as usize;
          let _ = crate::download_original as usize;
          let _ = crate::build_client as usize;
          let _ = crate::decode_envelope::<serde_json::Value> as usize;
          let _ = crate::map_error_code as usize;
      }
  }
  ```
  And create `core/synology-api/tests/real_nas_ignored.rs`:
  ```rust
  //! Manual integration test against a real Synology NAS. Not run by default.
  //! Run with:
  //!   SYNO_HOST=https://192.168.1.10:5001 SYNO_USER=photouser SYNO_PASS=... \
  //!   SYNO_OTP=123456 cargo test -p synology-api --test real_nas_ignored -- --ignored --nocapture
  //! READ-ONLY: logs in, probes capabilities, lists the first page of the personal
  //! space, then logs out. Never writes to or deletes from the NAS.

  use models::{Connection, Space};
  use synology_api::transport::Transport;
  use synology_api::{list_items, login, logout, probe_capabilities};

  fn env(key: &str) -> String {
      std::env::var(key).unwrap_or_else(|_| panic!("env var {key} must be set for the real NAS test"))
  }

  #[tokio::test]
  #[ignore = "hits a real NAS; requires SYNO_* env vars"]
  async fn real_nas_login_probe_list_logout() {
      let host = env("SYNO_HOST");
      let user = env("SYNO_USER");
      let pass = env("SYNO_PASS");
      let otp = std::env::var("SYNO_OTP").ok();
      let connection = Connection { host, verify_tls: true, pinned_cert_der: None };
      let transport = Transport::new(&connection).expect("transport builds against real NAS");
      let session = login(&transport, &user, &pass, otp.as_deref()).await
          .expect("real login should succeed with valid creds + OTP");
      assert!(!session.sid.is_empty(), "sid must be non-empty");
      println!("logged in as {}, syno_token present: {}", session.username, session.syno_token.is_some());
      let caps = probe_capabilities(&transport).await.expect("capability probe should succeed");
      assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Browse.Item"), "NAS must advertise SYNO.Foto.Browse.Item");
      println!("discovered {} capabilities", caps.len());
      let version = synology_api::pin_version(&caps, "SYNO.Foto.Browse.Item", 1)
          .expect("Browse.Item must be available");
      let assets = list_items(&transport, &session.sid, Space::Personal, 0, 25, version).await
          .expect("listing first page should succeed");
      println!("first page returned {} assets", assets.len());
      if let Some(first) = assets.first() {
          assert!(!first.cache_key.is_empty(), "asset cache_key must be populated");
      }
      logout(&transport, &session.sid).await.expect("logout should succeed");
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p synology-api facade_tests
  ```
  Expected: compile error `cannot find value login in crate root` (re-exports not yet added).
- [ ] Minimal implementation. Set the top of `core/synology-api/src/lib.rs` to:
  ```rust
  pub const VERSION: &str = env!("CARGO_PKG_VERSION");

  pub mod auth;
  pub mod browse;
  pub mod download;
  pub mod envelope;
  pub mod info;
  pub mod namespace;
  pub mod thumbnail;
  pub mod transport;

  pub use auth::{login, logout};
  pub use browse::{list_albums, list_items};
  pub use download::download_original;
  pub use envelope::{decode_envelope, map_error_code, SynoError, SynoResponse};
  pub use info::{pin_version, probe_capabilities};
  pub use thumbnail::fetch_thumbnail;
  pub use transport::{build_client, Transport};
  ```
  (Keep the `facade_tests` module at the bottom.)
- [ ] Run-to-pass:
  ```
  cargo test -p synology-api
  cargo test -p synology-api --test real_nas_ignored
  ```
  Expected: all crate tests pass including `facade_tests::reexports_are_reachable ... ok`; the real-NAS test reports `1 ignored`, `0 passed; 0 failed; 1 ignored`.
- [ ] (Optional, manual) Run against the real NAS to validate the reverse-engineered contract; if field names differ, escalate to amend the contract rather than forking:
  ```
  SYNO_HOST=https://192.168.1.10:5001 SYNO_USER=photouser SYNO_PASS='...' SYNO_OTP=123456 cargo test -p synology-api --test real_nas_ignored -- --ignored --nocapture
  ```
- [ ] Commit:
  ```
  git add core/synology-api/src/lib.rs core/synology-api/tests/real_nas_ignored.rs
  git commit -m "Expose flat synology-api facade re-exports and ignored real-NAS smoke test"
  ```

---

### Task 24: Embed schema DDL and run migrations (`persistence/schema.rs`)

**Files**
- Modify: `core/persistence/Cargo.toml`
- Modify: `core/persistence/src/lib.rs` (Store facade)
- Create: `core/persistence/src/schema.rs` (+ inline `#[cfg(test)]`)

**Interfaces**
- Consumes: `models::CoreError` (Task 5).
- Produces: `pub struct Store { pub(crate) conn: rusqlite::Connection }`; `pub fn Store::open_in_memory() -> Result<Store, CoreError>`; `pub fn Store::open_at(path: &std::path::Path) -> Result<Store, CoreError>`; `pub(crate) fn run_migrations(conn: &rusqlite::Connection) -> Result<(), CoreError>` (re-exported for tests); `pub fn Store::schema_version(&self) -> Result<i64, CoreError>`. Schema per the SQLITE SCHEMA section below.

**SQLite schema (embedded DDL):**
```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS assets (
    rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
    space          INTEGER NOT NULL,            -- 0 Personal, 1 Shared
    server_id      INTEGER NOT NULL,            -- Synology item id (identity within space)
    cache_key      TEXT    NOT NULL,            -- version token, NOT identity
    filename       TEXT    NOT NULL,
    media_kind     INTEGER NOT NULL DEFAULT 2,  -- 0 photo, 1 video, 2 unknown
    taken_at       INTEGER,
    added_at       INTEGER,
    width          INTEGER,
    height         INTEGER,
    file_size      INTEGER,
    server_version INTEGER,
    updated_at     INTEGER NOT NULL,
    UNIQUE (space, server_id)
);
CREATE INDEX IF NOT EXISTS idx_assets_space_taken ON assets (space, taken_at DESC, server_id DESC);
CREATE INDEX IF NOT EXISTS idx_assets_space_ver   ON assets (space, server_id, server_version);

CREATE TABLE IF NOT EXISTS albums (
    rowid_pk        INTEGER PRIMARY KEY AUTOINCREMENT,
    space           INTEGER NOT NULL,
    server_id       INTEGER NOT NULL,
    name            TEXT    NOT NULL,
    item_count      INTEGER NOT NULL DEFAULT 0,
    cover_cache_key TEXT,
    updated_at      INTEGER NOT NULL,
    UNIQUE (space, server_id)
);
CREATE INDEX IF NOT EXISTS idx_albums_space ON albums (space, name);

CREATE TABLE IF NOT EXISTS sync_state (
    space                  INTEGER PRIMARY KEY,
    initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
    expected_total         INTEGER NOT NULL DEFAULT 0,
    last_offset            INTEGER NOT NULL DEFAULT 0,
    last_page_limit        INTEGER NOT NULL DEFAULT 0,
    highest_seen_version   INTEGER,
    last_crawl_at          INTEGER,
    last_reconcile_at      INTEGER
);

CREATE TABLE IF NOT EXISTS schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- seeded: ('schema_version','1')
```
On-disk thumbnail file path (owned by the core, not the DB): `{cache_dir}/thumbs/{space}/{server_id}/{size}_{cache_key}.jpg`; a stale `cache_key` yields a new filename, orphaning the old.

**TDD steps**

- [ ] Set `core/persistence/Cargo.toml` `[dependencies]`:
  ```toml
  [dependencies]
  rusqlite = { version = "0.32", features = ["bundled"] }
  models = { path = "../models" }
  thiserror = "1"
  tracing.workspace = true
  ```
- [ ] Write the failing test in `core/persistence/src/schema.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;

      #[test]
      fn migrations_create_all_tables_and_seed_version() {
          let store = crate::Store::open_in_memory().expect("open");
          assert_eq!(store.schema_version().expect("version"), 1);
          let names: Vec<String> = {
              let mut stmt = store.conn
                  .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").unwrap();
              stmt.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|r| r.unwrap()).collect()
          };
          for expected in ["albums", "assets", "schema_meta", "sync_state"] {
              assert!(names.contains(&expected.to_string()), "missing table {expected}");
          }
      }

      #[test]
      fn migrations_are_idempotent() {
          let store = crate::Store::open_in_memory().expect("open");
          run_migrations(&store.conn).expect("rerun");
          assert_eq!(store.schema_version().expect("version"), 1);
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p persistence schema::tests
  ```
  Expected: compile error / unresolved `crate::Store`, `run_migrations`.
- [ ] Minimal implementation. Create `core/persistence/src/schema.rs`:
  ```rust
  use models::CoreError;
  use rusqlite::Connection;

  const DDL: &str = r#"
  PRAGMA journal_mode = WAL;
  PRAGMA foreign_keys = ON;

  CREATE TABLE IF NOT EXISTS assets (
      rowid_pk       INTEGER PRIMARY KEY AUTOINCREMENT,
      space          INTEGER NOT NULL,
      server_id      INTEGER NOT NULL,
      cache_key      TEXT    NOT NULL,
      filename       TEXT    NOT NULL,
      media_kind     INTEGER NOT NULL DEFAULT 2,
      taken_at       INTEGER,
      added_at       INTEGER,
      width          INTEGER,
      height         INTEGER,
      file_size      INTEGER,
      server_version INTEGER,
      updated_at     INTEGER NOT NULL,
      UNIQUE (space, server_id)
  );
  CREATE INDEX IF NOT EXISTS idx_assets_space_taken ON assets (space, taken_at DESC, server_id DESC);
  CREATE INDEX IF NOT EXISTS idx_assets_space_ver   ON assets (space, server_id, server_version);

  CREATE TABLE IF NOT EXISTS albums (
      rowid_pk        INTEGER PRIMARY KEY AUTOINCREMENT,
      space           INTEGER NOT NULL,
      server_id       INTEGER NOT NULL,
      name            TEXT    NOT NULL,
      item_count      INTEGER NOT NULL DEFAULT 0,
      cover_cache_key TEXT,
      updated_at      INTEGER NOT NULL,
      UNIQUE (space, server_id)
  );
  CREATE INDEX IF NOT EXISTS idx_albums_space ON albums (space, name);

  CREATE TABLE IF NOT EXISTS sync_state (
      space                  INTEGER PRIMARY KEY,
      initial_crawl_complete INTEGER NOT NULL DEFAULT 0,
      expected_total         INTEGER NOT NULL DEFAULT 0,
      last_offset            INTEGER NOT NULL DEFAULT 0,
      last_page_limit        INTEGER NOT NULL DEFAULT 0,
      highest_seen_version   INTEGER,
      last_crawl_at          INTEGER,
      last_reconcile_at      INTEGER
  );

  CREATE TABLE IF NOT EXISTS schema_meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
  );
  "#;

  fn map_sql(e: rusqlite::Error) -> CoreError {
      CoreError::Storage { message: e.to_string() }
  }

  pub(crate) fn run_migrations(conn: &Connection) -> Result<(), CoreError> {
      conn.execute_batch(DDL).map_err(map_sql)?;
      conn.execute(
          "INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', '1')",
          [],
      ).map_err(map_sql)?;
      Ok(())
  }
  ```
  Rewrite `core/persistence/src/lib.rs`:
  ```rust
  //! SQLite persistence via rusqlite: migrations and windowed queries.

  mod schema;
  pub use schema::run_migrations;

  use models::CoreError;
  use rusqlite::Connection;
  use std::path::Path;

  pub struct Store {
      pub(crate) conn: Connection,
  }

  impl Store {
      pub fn open_in_memory() -> Result<Store, CoreError> {
          let conn = Connection::open_in_memory()
              .map_err(|e| CoreError::Storage { message: e.to_string() })?;
          schema::run_migrations(&conn)?;
          Ok(Store { conn })
      }

      pub fn open_at(path: &Path) -> Result<Store, CoreError> {
          let conn = Connection::open(path)
              .map_err(|e| CoreError::Storage { message: e.to_string() })?;
          schema::run_migrations(&conn)?;
          Ok(Store { conn })
      }

      pub fn schema_version(&self) -> Result<i64, CoreError> {
          self.conn
              .query_row("SELECT value FROM schema_meta WHERE key = 'schema_version'", [], |r| r.get::<_, String>(0))
              .map_err(|e| CoreError::Storage { message: e.to_string() })?
              .parse::<i64>()
              .map_err(|e| CoreError::Storage { message: e.to_string() })
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p persistence schema::tests
  ```
  Expected: `test result: ok. 2 passed`.
- [ ] Commit:
  ```
  git add core/persistence
  git commit -m "Add SQLite schema and migration runner for persistence crate"
  ```

---

### Task 25: Asset upsert, windowed fetch, and count (`persistence/assets.rs`)

**Files**
- Create: `core/persistence/src/assets.rs` (+ inline `#[cfg(test)]`)
- Modify: `core/persistence/src/lib.rs`

**Interfaces**
- Consumes: `models::{Asset, Space, MediaKind, CoreError}`; `Store` (Task 24).
- Produces (methods on `Store`): `pub fn upsert_asset(&self, asset: &Asset) -> Result<(), CoreError>`; `pub fn upsert_assets(&self, assets: &[Asset]) -> Result<(), CoreError>`; `pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError>` (newest-first by `taken_at` then `server_id`, NULLs last); `pub fn asset_count(&self, space: Space) -> Result<u64, CoreError>`; `pub(crate) fn space_to_int`/`int_to_space`/`media_kind_to_int`/`int_to_media_kind`.

**TDD steps**

- [ ] Write the failing test in `core/persistence/src/assets.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::Store;
      use models::{Asset, MediaKind, Space};

      fn asset(space: Space, id: i64, taken: Option<i64>, ver: Option<i64>) -> Asset {
          Asset {
              id, cache_key: format!("ck{id}"), filename: format!("IMG_{id}.jpg"),
              media_kind: MediaKind::Photo, taken_at: taken, added_at: Some(1000),
              width: Some(4000), height: Some(3000), file_size: Some(2_000_000),
              space, server_version: ver,
          }
      }

      #[test]
      fn upsert_then_count_and_fetch_newest_first() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
          store.upsert_asset(&asset(Space::Personal, 2, Some(300), Some(1))).unwrap();
          store.upsert_asset(&asset(Space::Personal, 3, Some(200), Some(1))).unwrap();
          store.upsert_asset(&asset(Space::Shared, 9, Some(999), Some(1))).unwrap();
          assert_eq!(store.asset_count(Space::Personal).unwrap(), 3);
          assert_eq!(store.asset_count(Space::Shared).unwrap(), 1);
          let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
          let ids: Vec<i64> = page.iter().map(|a| a.id).collect();
          assert_eq!(ids, vec![2, 3, 1]);
          assert_eq!(page[0].space, Space::Personal);
      }

      #[test]
      fn upsert_is_idempotent_on_space_server_id() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
          let mut updated = asset(Space::Personal, 1, Some(555), Some(2));
          updated.cache_key = "ck1-new".into();
          store.upsert_asset(&updated).unwrap();
          assert_eq!(store.asset_count(Space::Personal).unwrap(), 1);
          let page = store.fetch_assets(Space::Personal, 0, 10).unwrap();
          assert_eq!(page[0].cache_key, "ck1-new");
          assert_eq!(page[0].taken_at, Some(555));
          assert_eq!(page[0].server_version, Some(2));
      }

      #[test]
      fn null_taken_at_sorts_last() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_asset(&asset(Space::Personal, 1, Some(100), Some(1))).unwrap();
          store.upsert_asset(&asset(Space::Personal, 2, None, Some(1))).unwrap();
          let ids: Vec<i64> = store.fetch_assets(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
          assert_eq!(ids, vec![1, 2]);
      }

      #[test]
      fn windowing_offset_limit() {
          let store = Store::open_in_memory().unwrap();
          for id in 1..=5 {
              store.upsert_asset(&asset(Space::Personal, id, Some(id * 10), Some(1))).unwrap();
          }
          let ids: Vec<i64> = store.fetch_assets(Space::Personal, 1, 2).unwrap().iter().map(|a| a.id).collect();
          assert_eq!(ids, vec![4, 3]);
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p persistence assets::tests
  ```
  Expected: compile error `Store::upsert_asset` not found.
- [ ] Minimal implementation. Create `core/persistence/src/assets.rs`:
  ```rust
  use crate::Store;
  use models::{Asset, CoreError, MediaKind, Space};
  use rusqlite::params;

  pub(crate) fn space_to_int(space: Space) -> i64 {
      match space { Space::Personal => 0, Space::Shared => 1 }
  }
  pub(crate) fn int_to_space(v: i64) -> Space {
      match v { 1 => Space::Shared, _ => Space::Personal }
  }
  pub(crate) fn media_kind_to_int(k: MediaKind) -> i64 {
      match k { MediaKind::Photo => 0, MediaKind::Video => 1, MediaKind::Unknown => 2 }
  }
  pub(crate) fn int_to_media_kind(v: i64) -> MediaKind {
      match v { 0 => MediaKind::Photo, 1 => MediaKind::Video, _ => MediaKind::Unknown }
  }

  fn now_secs() -> i64 {
      std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
  }
  fn map_sql(e: rusqlite::Error) -> CoreError {
      CoreError::Storage { message: e.to_string() }
  }

  impl Store {
      pub fn upsert_asset(&self, asset: &Asset) -> Result<(), CoreError> {
          self.conn.execute(
              "INSERT INTO assets
                  (space, server_id, cache_key, filename, media_kind,
                   taken_at, added_at, width, height, file_size, server_version, updated_at)
               VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)
               ON CONFLICT(space, server_id) DO UPDATE SET
                   cache_key      = excluded.cache_key,
                   filename       = excluded.filename,
                   media_kind     = excluded.media_kind,
                   taken_at       = excluded.taken_at,
                   added_at       = excluded.added_at,
                   width          = excluded.width,
                   height         = excluded.height,
                   file_size      = excluded.file_size,
                   server_version = excluded.server_version,
                   updated_at     = excluded.updated_at",
              params![
                  space_to_int(asset.space), asset.id, asset.cache_key, asset.filename,
                  media_kind_to_int(asset.media_kind), asset.taken_at, asset.added_at,
                  asset.width, asset.height, asset.file_size, asset.server_version, now_secs(),
              ],
          ).map_err(map_sql)?;
          Ok(())
      }

      pub fn upsert_assets(&self, assets: &[Asset]) -> Result<(), CoreError> {
          self.conn.execute_batch("BEGIN").map_err(map_sql)?;
          for a in assets {
              if let Err(e) = self.upsert_asset(a) {
                  let _ = self.conn.execute_batch("ROLLBACK");
                  return Err(e);
              }
          }
          self.conn.execute_batch("COMMIT").map_err(map_sql)?;
          Ok(())
      }

      pub fn asset_count(&self, space: Space) -> Result<u64, CoreError> {
          let n: i64 = self.conn.query_row(
              "SELECT COUNT(*) FROM assets WHERE space = ?1",
              params![space_to_int(space)], |r| r.get(0),
          ).map_err(map_sql)?;
          Ok(n as u64)
      }

      pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
          let mut stmt = self.conn.prepare(
              "SELECT server_id, cache_key, filename, media_kind, taken_at,
                      added_at, width, height, file_size, server_version, space
               FROM assets
               WHERE space = ?1
               ORDER BY (taken_at IS NULL) ASC, taken_at DESC, server_id DESC
               LIMIT ?2 OFFSET ?3",
          ).map_err(map_sql)?;
          let rows = stmt.query_map(
              params![space_to_int(space), limit as i64, offset as i64],
              |r| Ok(Asset {
                  id: r.get(0)?,
                  cache_key: r.get(1)?,
                  filename: r.get(2)?,
                  media_kind: int_to_media_kind(r.get::<_, i64>(3)?),
                  taken_at: r.get(4)?,
                  added_at: r.get(5)?,
                  width: r.get::<_, Option<i64>>(6)?.map(|v| v as u32),
                  height: r.get::<_, Option<i64>>(7)?.map(|v| v as u32),
                  file_size: r.get::<_, Option<i64>>(8)?.map(|v| v as u64),
                  server_version: r.get(9)?,
                  space: int_to_space(r.get::<_, i64>(10)?),
              }),
          ).map_err(map_sql)?;
          let mut out = Vec::new();
          for row in rows { out.push(row.map_err(map_sql)?); }
          Ok(out)
      }
  }
  ```
  Add to `core/persistence/src/lib.rs` after `pub use schema::run_migrations;`:
  ```rust
  mod assets;
  pub(crate) use assets::{int_to_space, space_to_int};
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p persistence assets::tests
  ```
  Expected: `test result: ok. 4 passed`.
- [ ] Commit:
  ```
  git add core/persistence
  git commit -m "Add asset upsert, windowed fetch, and per-space count"
  ```

---

### Task 26: Album upsert and fetch (`persistence/albums.rs`)

**Files**
- Create: `core/persistence/src/albums.rs` (+ inline `#[cfg(test)]`)
- Modify: `core/persistence/src/lib.rs` (add `mod albums;`)

**Interfaces**
- Consumes: `models::{Album, Space, CoreError}`; `Store`; `space_to_int`/`int_to_space` (Task 25).
- Produces (methods on `Store`): `pub fn upsert_album(&self, album: &Album) -> Result<(), CoreError>`; `pub fn fetch_albums(&self, space: Space) -> Result<Vec<Album>, CoreError>` (ordered by name within space).

**TDD steps**

- [ ] Write the failing test in `core/persistence/src/albums.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::Store;
      use models::{Album, Space};

      fn album(space: Space, id: i64, name: &str) -> Album {
          Album { id, name: name.to_string(), item_count: 5, cover_cache_key: Some(format!("cover{id}")), space }
      }

      #[test]
      fn upsert_and_fetch_albums_ordered_by_name_within_space() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_album(&album(Space::Personal, 1, "Zebra")).unwrap();
          store.upsert_album(&album(Space::Personal, 2, "Apple")).unwrap();
          store.upsert_album(&album(Space::Shared, 3, "ShouldNotAppear")).unwrap();
          let names: Vec<String> = store.fetch_albums(Space::Personal).unwrap().iter().map(|a| a.name.clone()).collect();
          assert_eq!(names, vec!["Apple", "Zebra"]);
      }

      #[test]
      fn upsert_album_idempotent() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_album(&album(Space::Personal, 1, "Trip")).unwrap();
          let mut updated = album(Space::Personal, 1, "Trip 2024");
          updated.item_count = 42;
          store.upsert_album(&updated).unwrap();
          let albums = store.fetch_albums(Space::Personal).unwrap();
          assert_eq!(albums.len(), 1);
          assert_eq!(albums[0].name, "Trip 2024");
          assert_eq!(albums[0].item_count, 42);
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p persistence albums::tests
  ```
  Expected: compile error `Store::upsert_album` not found.
- [ ] Minimal implementation. Create `core/persistence/src/albums.rs`:
  ```rust
  use crate::assets::{int_to_space, space_to_int};
  use crate::Store;
  use models::{Album, CoreError, Space};
  use rusqlite::params;

  fn now_secs() -> i64 {
      std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
  }
  fn map_sql(e: rusqlite::Error) -> CoreError {
      CoreError::Storage { message: e.to_string() }
  }

  impl Store {
      pub fn upsert_album(&self, album: &Album) -> Result<(), CoreError> {
          self.conn.execute(
              "INSERT INTO albums
                  (space, server_id, name, item_count, cover_cache_key, updated_at)
               VALUES (?1,?2,?3,?4,?5,?6)
               ON CONFLICT(space, server_id) DO UPDATE SET
                   name            = excluded.name,
                   item_count      = excluded.item_count,
                   cover_cache_key = excluded.cover_cache_key,
                   updated_at      = excluded.updated_at",
              params![
                  space_to_int(album.space), album.id, album.name,
                  album.item_count as i64, album.cover_cache_key, now_secs(),
              ],
          ).map_err(map_sql)?;
          Ok(())
      }

      pub fn fetch_albums(&self, space: Space) -> Result<Vec<Album>, CoreError> {
          let mut stmt = self.conn.prepare(
              "SELECT server_id, name, item_count, cover_cache_key, space
               FROM albums WHERE space = ?1 ORDER BY name ASC",
          ).map_err(map_sql)?;
          let rows = stmt.query_map(params![space_to_int(space)], |r| Ok(Album {
              id: r.get(0)?,
              name: r.get(1)?,
              item_count: r.get::<_, i64>(2)? as u32,
              cover_cache_key: r.get(3)?,
              space: int_to_space(r.get::<_, i64>(4)?),
          })).map_err(map_sql)?;
          let mut out = Vec::new();
          for row in rows { out.push(row.map_err(map_sql)?); }
          Ok(out)
      }
  }
  ```
  Add `mod albums;` to `core/persistence/src/lib.rs`.
- [ ] Run-to-pass:
  ```
  cargo test -p persistence albums::tests
  ```
  Expected: `test result: ok. 2 passed`.
- [ ] Commit:
  ```
  git add core/persistence
  git commit -m "Add album upsert and per-space fetch"
  ```

---

### Task 27: Sync-state read/write and barrier flip (`persistence/sync_state.rs`)

**Files**
- Create: `core/persistence/src/sync_state.rs` (+ inline `#[cfg(test)]`)
- Modify: `core/persistence/src/lib.rs` (add `mod sync_state; pub use sync_state::SyncStateRow;`)

**Interfaces**
- Consumes: `models::{Space, CrawlProgress, CoreError}`; `Store`; `space_to_int` (Task 25); `asset_count` (Task 25).
- Produces: `pub struct SyncStateRow { pub space, pub initial_crawl_complete: bool, pub expected_total: u64, pub last_offset: u32, pub last_page_limit: u32, pub highest_seen_version: Option<i64>, pub last_crawl_at: Option<i64>, pub last_reconcile_at: Option<i64> }`; methods on `Store`: `load_sync_state`, `save_cursor`, `set_crawl_complete`, `set_highest_version` (ratchets upward only), `set_reconcile_at`, `crawl_progress` (reads persisted state; `done` = `asset_count`).

**TDD steps**

- [ ] Write the failing test in `core/persistence/src/sync_state.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::Store;
      use models::Space;

      #[test]
      fn default_state_when_no_row() {
          let store = Store::open_in_memory().unwrap();
          let s = store.load_sync_state(Space::Personal).unwrap();
          assert!(!s.initial_crawl_complete);
          assert_eq!(s.expected_total, 0);
          assert_eq!(s.last_offset, 0);
          assert_eq!(s.highest_seen_version, None);
      }

      #[test]
      fn save_cursor_then_reload() {
          let store = Store::open_in_memory().unwrap();
          store.save_cursor(Space::Personal, 200, 100, 1500).unwrap();
          let s = store.load_sync_state(Space::Personal).unwrap();
          assert_eq!(s.last_offset, 200);
          assert_eq!(s.last_page_limit, 100);
          assert_eq!(s.expected_total, 1500);
          assert!(!s.initial_crawl_complete);
      }

      #[test]
      fn spaces_are_independent_rows() {
          let store = Store::open_in_memory().unwrap();
          store.save_cursor(Space::Personal, 50, 50, 300).unwrap();
          store.save_cursor(Space::Shared, 10, 50, 80).unwrap();
          assert_eq!(store.load_sync_state(Space::Personal).unwrap().last_offset, 50);
          assert_eq!(store.load_sync_state(Space::Shared).unwrap().last_offset, 10);
          assert_eq!(store.load_sync_state(Space::Shared).unwrap().expected_total, 80);
      }

      #[test]
      fn set_complete_and_highest_version_and_progress() {
          let store = Store::open_in_memory().unwrap();
          store.save_cursor(Space::Personal, 0, 100, 0).unwrap();
          store.set_highest_version(Space::Personal, 42).unwrap();
          store.set_crawl_complete(Space::Personal, true, 9999).unwrap();
          let s = store.load_sync_state(Space::Personal).unwrap();
          assert!(s.initial_crawl_complete);
          assert_eq!(s.highest_seen_version, Some(42));
          assert_eq!(s.last_crawl_at, Some(9999));
          store.save_cursor(Space::Personal, 100, 100, 7).unwrap();
          let p = store.crawl_progress(Space::Personal).unwrap();
          assert_eq!(p.total, 7);
          assert!(p.complete);
          assert_eq!(p.space, Space::Personal);
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p persistence sync_state::tests
  ```
  Expected: compile error `load_sync_state` not found.
- [ ] Minimal implementation. Create `core/persistence/src/sync_state.rs`:
  ```rust
  use crate::assets::space_to_int;
  use crate::Store;
  use models::{CoreError, CrawlProgress, Space};
  use rusqlite::{params, OptionalExtension};

  #[derive(Clone, Debug)]
  pub struct SyncStateRow {
      pub space: Space,
      pub initial_crawl_complete: bool,
      pub expected_total: u64,
      pub last_offset: u32,
      pub last_page_limit: u32,
      pub highest_seen_version: Option<i64>,
      pub last_crawl_at: Option<i64>,
      pub last_reconcile_at: Option<i64>,
  }

  fn map_sql(e: rusqlite::Error) -> CoreError {
      CoreError::Storage { message: e.to_string() }
  }

  fn ensure_row(store: &Store, space: Space) -> Result<(), CoreError> {
      store.conn.execute(
          "INSERT OR IGNORE INTO sync_state (space) VALUES (?1)",
          params![space_to_int(space)],
      ).map_err(map_sql)?;
      Ok(())
  }

  impl Store {
      pub fn load_sync_state(&self, space: Space) -> Result<SyncStateRow, CoreError> {
          let row = self.conn.query_row(
              "SELECT initial_crawl_complete, expected_total, last_offset,
                      last_page_limit, highest_seen_version, last_crawl_at, last_reconcile_at
               FROM sync_state WHERE space = ?1",
              params![space_to_int(space)],
              |r| Ok((
                  r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?,
                  r.get::<_, i64>(3)?, r.get::<_, Option<i64>>(4)?,
                  r.get::<_, Option<i64>>(5)?, r.get::<_, Option<i64>>(6)?,
              )),
          ).optional().map_err(map_sql)?;
          match row {
              Some((complete, total, offset, limit, hv, lca, lra)) => Ok(SyncStateRow {
                  space,
                  initial_crawl_complete: complete != 0,
                  expected_total: total as u64,
                  last_offset: offset as u32,
                  last_page_limit: limit as u32,
                  highest_seen_version: hv,
                  last_crawl_at: lca,
                  last_reconcile_at: lra,
              }),
              None => Ok(SyncStateRow {
                  space,
                  initial_crawl_complete: false,
                  expected_total: 0,
                  last_offset: 0,
                  last_page_limit: 0,
                  highest_seen_version: None,
                  last_crawl_at: None,
                  last_reconcile_at: None,
              }),
          }
      }

      pub fn save_cursor(&self, space: Space, last_offset: u32, last_page_limit: u32, expected_total: u64) -> Result<(), CoreError> {
          ensure_row(self, space)?;
          self.conn.execute(
              "UPDATE sync_state SET last_offset = ?2, last_page_limit = ?3, expected_total = ?4 WHERE space = ?1",
              params![space_to_int(space), last_offset as i64, last_page_limit as i64, expected_total as i64],
          ).map_err(map_sql)?;
          Ok(())
      }

      pub fn set_crawl_complete(&self, space: Space, complete: bool, at_secs: i64) -> Result<(), CoreError> {
          ensure_row(self, space)?;
          self.conn.execute(
              "UPDATE sync_state SET initial_crawl_complete = ?2, last_crawl_at = ?3 WHERE space = ?1",
              params![space_to_int(space), complete as i64, at_secs],
          ).map_err(map_sql)?;
          Ok(())
      }

      pub fn set_highest_version(&self, space: Space, version: i64) -> Result<(), CoreError> {
          ensure_row(self, space)?;
          self.conn.execute(
              "UPDATE sync_state
               SET highest_seen_version =
                   CASE WHEN highest_seen_version IS NULL OR highest_seen_version < ?2
                        THEN ?2 ELSE highest_seen_version END
               WHERE space = ?1",
              params![space_to_int(space), version],
          ).map_err(map_sql)?;
          Ok(())
      }

      pub fn set_reconcile_at(&self, space: Space, at_secs: i64) -> Result<(), CoreError> {
          ensure_row(self, space)?;
          self.conn.execute(
              "UPDATE sync_state SET last_reconcile_at = ?2 WHERE space = ?1",
              params![space_to_int(space), at_secs],
          ).map_err(map_sql)?;
          Ok(())
      }

      pub fn crawl_progress(&self, space: Space) -> Result<CrawlProgress, CoreError> {
          let state = self.load_sync_state(space)?;
          let done = self.asset_count(space)?;
          Ok(CrawlProgress { space, done, total: state.expected_total, complete: state.initial_crawl_complete })
      }
  }
  ```
  Add to `core/persistence/src/lib.rs`:
  ```rust
  mod sync_state;
  pub use sync_state::SyncStateRow;
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p persistence sync_state::tests
  ```
  Expected: `test result: ok. 4 passed`.
- [ ] Commit:
  ```
  git add core/persistence
  git commit -m "Add sync-state persistence with resumable cursor and barrier"
  ```

---

### Task 28: PageSource trait and AssetPage for the sync engine (`sync-engine/lib.rs`)

**Files**
- Modify: `core/sync-engine/Cargo.toml`
- Modify: `core/sync-engine/src/lib.rs` (types + inline `#[cfg(test)]`)
- Create: `core/sync-engine/src/crawl.rs` (stub, filled in Task 29)
- Create: `core/sync-engine/src/delta.rs` (stub, filled in Task 30)

**Interfaces**
- Consumes: `models::{Asset, Space, CoreError}`.
- Produces: `pub struct AssetPage { pub assets: Vec<Asset>, pub total: u64 }` (`#[derive(Clone, Debug)]`); `#[async_trait::async_trait] pub trait PageSource: Send + Sync { async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError>; }`. Group A's facade implements this for real over `synology-api::list_items`; the sync engine never depends on reqwest.

**TDD steps**

- [ ] Ensure `core/sync-engine/Cargo.toml` `[dependencies]`/dev-deps (already set in Task 2) include:
  ```toml
  [dependencies]
  models = { path = "../models" }
  synology-api = { path = "../synology-api" }
  persistence = { path = "../persistence" }
  thiserror.workspace = true
  tracing.workspace = true
  async-trait.workspace = true

  [dev-dependencies]
  tokio = { version = "1", features = ["macros", "rt"] }
  ```
- [ ] Write the failing test in `core/sync-engine/src/lib.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use models::{Asset, MediaKind, Space};
      use std::sync::Mutex;

      fn asset(id: i64, ver: i64) -> Asset {
          Asset {
              id, cache_key: format!("ck{id}"), filename: format!("IMG_{id}.jpg"),
              media_kind: MediaKind::Photo, taken_at: Some(id * 10), added_at: Some(1),
              width: Some(100), height: Some(100), file_size: Some(1),
              space: Space::Personal, server_version: Some(ver),
          }
      }

      pub struct FakeSource {
          pub pages: Vec<AssetPage>,
          pub calls: Mutex<Vec<(u32, u32)>>,
      }

      #[async_trait::async_trait]
      impl PageSource for FakeSource {
          async fn list_items(&self, _space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
              self.calls.lock().unwrap().push((offset, limit));
              let idx = (offset / limit) as usize;
              Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage { assets: vec![], total: 0 }))
          }
      }

      #[tokio::test]
      async fn fake_source_returns_pages_in_order() {
          let src = FakeSource {
              pages: vec![
                  AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                  AssetPage { assets: vec![asset(3, 1)], total: 3 },
              ],
              calls: Mutex::new(vec![]),
          };
          let p0 = src.list_items(Space::Personal, 0, 2).await.unwrap();
          assert_eq!(p0.assets.len(), 2);
          assert_eq!(p0.total, 3);
          let p1 = src.list_items(Space::Personal, 2, 2).await.unwrap();
          assert_eq!(p1.assets.len(), 1);
          assert_eq!(src.calls.lock().unwrap().as_slice(), &[(0, 2), (2, 2)]);
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p sync-engine
  ```
  Expected: compile error `AssetPage`, `PageSource` undefined; `async_trait` unresolved.
- [ ] Minimal implementation. Set the top of `core/sync-engine/src/lib.rs` (above the test module):
  ```rust
  //! Resumable progress-tracked crawl and delta reconciliation by server id/version.

  use models::{Asset, CoreError, Space};

  pub mod crawl;
  pub mod delta;

  /// One page of items from the server, plus the server-reported total for the space.
  #[derive(Clone, Debug)]
  pub struct AssetPage {
      pub assets: Vec<Asset>,
      pub total: u64,
  }

  /// Abstraction over the network list call so sync logic is testable without HTTP.
  /// Group A's facade implements this over synology-api; sync-engine only knows the trait.
  #[async_trait::async_trait]
  pub trait PageSource: Send + Sync {
      async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError>;
  }
  ```
  Create `core/sync-engine/src/crawl.rs`:
  ```rust
  // Crawler implementation lands in Task 29.
  ```
  Create `core/sync-engine/src/delta.rs`:
  ```rust
  // Delta reconciler lands in Task 30.
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p sync-engine
  ```
  Expected: `test result: ok. 1 passed`.
- [ ] Commit:
  ```
  git add core/sync-engine
  git commit -m "Add PageSource trait and AssetPage for sync engine"
  ```

---

### Task 29: Resumable progress-tracked crawl with barrier (`sync-engine/crawl.rs`)

**Files**
- Modify: `core/sync-engine/src/crawl.rs` (replace stub, + inline `#[cfg(test)]`)

**Interfaces**
- Consumes: `crate::{AssetPage, PageSource}` (Task 28); `persistence::Store` with `upsert_assets`, `save_cursor`, `set_crawl_complete`, `set_highest_version`, `load_sync_state`, `crawl_progress`, `asset_count` (Tasks 25, 27); `models::{Space, CrawlProgress, CoreError}`.
- Produces: `pub trait ProgressSink: Send + Sync { fn emit(&self, progress: CrawlProgress); }`; `pub struct Crawler<'a>` with `pub fn new(store: &'a Store, source: &'a dyn PageSource, page_limit: u32) -> Self` and `pub async fn crawl_space(&self, space: Space, sink: &dyn ProgressSink) -> Result<CrawlProgress, CoreError>`. Barrier per the schema section: `initial_crawl_complete` flips to 1 only when the final page returned fewer than `page_limit` items AND `offset >= expected_total`.

**TDD steps**

- [ ] Write the failing test in `core/sync-engine/src/crawl.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::{AssetPage, PageSource};
      use models::{Asset, CoreError, MediaKind, Space};
      use persistence::Store;
      use std::sync::Mutex;

      fn asset(id: i64, ver: i64) -> Asset {
          Asset {
              id, cache_key: format!("ck{id}"), filename: format!("IMG_{id}.jpg"),
              media_kind: MediaKind::Photo, taken_at: Some(id * 10), added_at: Some(1),
              width: Some(100), height: Some(100), file_size: Some(1),
              space: Space::Personal, server_version: Some(ver),
          }
      }

      struct ScriptedSource {
          pages: Vec<AssetPage>,
          calls: Mutex<Vec<(u32, u32)>>,
      }
      #[async_trait::async_trait]
      impl PageSource for ScriptedSource {
          async fn list_items(&self, _space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
              self.calls.lock().unwrap().push((offset, limit));
              let idx = (offset / limit) as usize;
              Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage { assets: vec![], total: self.pages_total() }))
          }
      }
      impl ScriptedSource {
          fn pages_total(&self) -> u64 { self.pages.first().map(|p| p.total).unwrap_or(0) }
      }

      struct CountingSink { events: Mutex<Vec<CrawlProgress>> }
      impl ProgressSink for CountingSink {
          fn emit(&self, p: CrawlProgress) { self.events.lock().unwrap().push(p); }
      }

      #[tokio::test]
      async fn full_crawl_persists_all_and_sets_barrier() {
          let store = Store::open_in_memory().unwrap();
          let src = ScriptedSource {
              pages: vec![
                  AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                  AssetPage { assets: vec![asset(3, 1)], total: 3 },
              ],
              calls: Mutex::new(vec![]),
          };
          let sink = CountingSink { events: Mutex::new(vec![]) };
          let crawler = Crawler::new(&store, &src, 2);
          let final_p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();
          assert_eq!(store.asset_count(Space::Personal).unwrap(), 3);
          assert!(final_p.complete);
          assert_eq!(final_p.done, 3);
          assert_eq!(final_p.total, 3);
          let st = store.load_sync_state(Space::Personal).unwrap();
          assert!(st.initial_crawl_complete);
          assert_eq!(st.highest_seen_version, Some(1));
          let events = sink.events.lock().unwrap();
          assert!(events.len() >= 2);
          assert!(events.last().unwrap().complete);
      }

      #[tokio::test]
      async fn interrupted_crawl_resumes_from_cursor() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_assets(&[asset(1, 1), asset(2, 1)]).unwrap();
          store.save_cursor(Space::Personal, 2, 2, 3).unwrap();
          let src = ScriptedSource {
              pages: vec![
                  AssetPage { assets: vec![asset(1, 1), asset(2, 1)], total: 3 },
                  AssetPage { assets: vec![asset(3, 1)], total: 3 },
              ],
              calls: Mutex::new(vec![]),
          };
          let sink = CountingSink { events: Mutex::new(vec![]) };
          let crawler = Crawler::new(&store, &src, 2);
          crawler.crawl_space(Space::Personal, &sink).await.unwrap();
          let calls = src.calls.lock().unwrap();
          assert_eq!(calls.first().copied(), Some((2, 2)));
          assert!(!calls.contains(&(0, 2)));
          assert_eq!(store.asset_count(Space::Personal).unwrap(), 3);
      }

      #[tokio::test]
      async fn completed_crawl_is_noop_on_recall() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_assets(&[asset(1, 1)]).unwrap();
          store.save_cursor(Space::Personal, 1, 2, 1).unwrap();
          store.set_crawl_complete(Space::Personal, true, 1).unwrap();
          let src = ScriptedSource { pages: vec![], calls: Mutex::new(vec![]) };
          let sink = CountingSink { events: Mutex::new(vec![]) };
          let crawler = Crawler::new(&store, &src, 2);
          let p = crawler.crawl_space(Space::Personal, &sink).await.unwrap();
          assert!(p.complete);
          assert!(src.calls.lock().unwrap().is_empty());
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p sync-engine crawl::tests
  ```
  Expected: compile error `Crawler`, `ProgressSink` undefined.
- [ ] Minimal implementation. Set the top of `core/sync-engine/src/crawl.rs` (above the test module):
  ```rust
  use crate::PageSource;
  use models::{CoreError, CrawlProgress, Space};
  use persistence::Store;

  fn now_secs() -> i64 {
      std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
  }

  /// Sync-engine-internal progress abstraction. Group A adapts FfiCrawlObserver onto this.
  pub trait ProgressSink: Send + Sync {
      fn emit(&self, progress: CrawlProgress);
  }

  pub struct Crawler<'a> {
      store: &'a Store,
      source: &'a dyn PageSource,
      page_limit: u32,
  }

  impl<'a> Crawler<'a> {
      pub fn new(store: &'a Store, source: &'a dyn PageSource, page_limit: u32) -> Self {
          Crawler { store, source, page_limit }
      }

      pub async fn crawl_space(&self, space: Space, sink: &dyn ProgressSink) -> Result<CrawlProgress, CoreError> {
          let state = self.store.load_sync_state(space)?;
          if state.initial_crawl_complete {
              let p = self.store.crawl_progress(space)?;
              sink.emit(p.clone());
              return Ok(p);
          }
          let mut offset = state.last_offset;
          let limit = self.page_limit;
          let mut expected_total = state.expected_total;
          loop {
              let page = self.source.list_items(space, offset, limit).await?;
              expected_total = page.total;
              let fetched = page.assets.len() as u32;
              let page_max_version = page.assets.iter().filter_map(|a| a.server_version).max();
              if fetched > 0 {
                  self.store.upsert_assets(&page.assets)?;
              }
              if let Some(v) = page_max_version {
                  self.store.set_highest_version(space, v)?;
              }
              offset += fetched;
              self.store.save_cursor(space, offset, limit, expected_total)?;
              let reached_end = fetched < limit;
              let barrier = reached_end && (offset as u64) >= expected_total;
              if barrier {
                  self.store.set_crawl_complete(space, true, now_secs())?;
              }
              let progress = self.store.crawl_progress(space)?;
              sink.emit(progress.clone());
              if reached_end {
                  return Ok(progress);
              }
          }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p sync-engine crawl::tests
  ```
  Expected: `test result: ok. 3 passed`.
- [ ] Commit:
  ```
  git add core/sync-engine
  git commit -m "Add resumable progress-tracked crawl with completion barrier"
  ```

---

### Task 30: Delta reconciliation by server id/version, clock-skew safe (`sync-engine/delta.rs`)

**Files**
- Modify: `core/sync-engine/src/delta.rs` (replace stub, + inline `#[cfg(test)]`)

**Interfaces**
- Consumes: `crate::{AssetPage, PageSource}` (Task 28); `persistence::Store` with `upsert_assets`, `set_highest_version`, `set_reconcile_at`, `load_sync_state`, `crawl_progress`, `fetch_assets`, `asset_count` (Tasks 25, 27); `models::{Space, CrawlProgress, CoreError}`.
- Produces: `pub struct DeltaReconciler<'a>` with `pub fn new(store: &'a Store, source: &'a dyn PageSource, page_limit: u32) -> Self` and `pub async fn reconcile(&self, space: Space) -> Result<CrawlProgress, CoreError>`. Reconcile decision is keyed ONLY on `(server_id, server_version)`, never on `taken_at`/`added_at`, so a clock-skewed timestamp cannot create a hole.

**TDD steps**

- [ ] Write the failing test in `core/sync-engine/src/delta.rs`:
  ```rust
  #[cfg(test)]
  mod tests {
      use super::*;
      use crate::{AssetPage, PageSource};
      use models::{Asset, CoreError, MediaKind, Space};
      use persistence::Store;

      fn asset_v(id: i64, ver: i64, taken: Option<i64>) -> Asset {
          Asset {
              id, cache_key: format!("ck{id}-v{ver}"), filename: format!("IMG_{id}.jpg"),
              media_kind: MediaKind::Photo, taken_at: taken, added_at: Some(1),
              width: Some(100), height: Some(100), file_size: Some(1),
              space: Space::Personal, server_version: Some(ver),
          }
      }

      struct ScriptedSource { pages: Vec<AssetPage> }
      #[async_trait::async_trait]
      impl PageSource for ScriptedSource {
          async fn list_items(&self, _space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
              let idx = (offset / limit) as usize;
              Ok(self.pages.get(idx).cloned().unwrap_or(AssetPage { assets: vec![], total: self.total() }))
          }
      }
      impl ScriptedSource {
          fn total(&self) -> u64 { self.pages.first().map(|p| p.total).unwrap_or(0) }
      }

      #[tokio::test]
      async fn changed_version_updates_row() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_assets(&[asset_v(1, 1, Some(100))]).unwrap();
          let src = ScriptedSource { pages: vec![AssetPage { assets: vec![asset_v(1, 2, Some(100))], total: 1 }] };
          let rec = DeltaReconciler::new(&store, &src, 100);
          rec.reconcile(Space::Personal).await.unwrap();
          let local = store.fetch_assets(Space::Personal, 0, 10).unwrap();
          assert_eq!(local.len(), 1);
          assert_eq!(local[0].server_version, Some(2));
          assert_eq!(local[0].cache_key, "ck1-v2");
          assert_eq!(store.load_sync_state(Space::Personal).unwrap().highest_seen_version, Some(2));
      }

      #[tokio::test]
      async fn new_id_is_added() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_assets(&[asset_v(1, 1, Some(100))]).unwrap();
          let src = ScriptedSource {
              pages: vec![AssetPage { assets: vec![asset_v(1, 1, Some(100)), asset_v(2, 1, Some(200))], total: 2 }],
          };
          let rec = DeltaReconciler::new(&store, &src, 100);
          rec.reconcile(Space::Personal).await.unwrap();
          assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
      }

      #[tokio::test]
      async fn clock_skew_does_not_create_a_hole() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_assets(&[asset_v(1, 1, Some(9_999))]).unwrap();
          store.set_reconcile_at(Space::Personal, 10_000).unwrap();
          let src = ScriptedSource {
              pages: vec![AssetPage { assets: vec![asset_v(1, 1, Some(9_999)), asset_v(2, 1, Some(5_000))], total: 2 }],
          };
          let rec = DeltaReconciler::new(&store, &src, 100);
          rec.reconcile(Space::Personal).await.unwrap();
          assert_eq!(store.asset_count(Space::Personal).unwrap(), 2);
          let ids: Vec<i64> = store.fetch_assets(Space::Personal, 0, 10).unwrap().iter().map(|a| a.id).collect();
          assert!(ids.contains(&2), "backdated new item was dropped (a hole)");
      }

      #[tokio::test]
      async fn unchanged_version_is_left_alone() {
          let store = Store::open_in_memory().unwrap();
          store.upsert_assets(&[asset_v(1, 1, Some(100))]).unwrap();
          let mut same = asset_v(1, 1, Some(100));
          same.cache_key = "server-sent-but-same-version".into();
          let src = ScriptedSource { pages: vec![AssetPage { assets: vec![same], total: 1 }] };
          let rec = DeltaReconciler::new(&store, &src, 100);
          rec.reconcile(Space::Personal).await.unwrap();
          let local = store.fetch_assets(Space::Personal, 0, 10).unwrap();
          assert_eq!(local[0].cache_key, "ck1-v1");
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p sync-engine delta::tests
  ```
  Expected: compile error `DeltaReconciler` undefined.
- [ ] Minimal implementation. Set the top of `core/sync-engine/src/delta.rs` (above the test module):
  ```rust
  use crate::PageSource;
  use models::{CoreError, CrawlProgress, Space};
  use persistence::Store;
  use std::collections::HashMap;

  fn now_secs() -> i64 {
      std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
  }

  pub struct DeltaReconciler<'a> {
      store: &'a Store,
      source: &'a dyn PageSource,
      page_limit: u32,
  }

  impl<'a> DeltaReconciler<'a> {
      pub fn new(store: &'a Store, source: &'a dyn PageSource, page_limit: u32) -> Self {
          DeltaReconciler { store, source, page_limit }
      }

      /// Reconcile local against server by (server_id, server_version) only.
      /// No timestamp is ever consulted to decide whether to import a row, so a
      /// clock-skewed or backdated taken_at cannot cause a missed item.
      pub async fn reconcile(&self, space: Space) -> Result<CrawlProgress, CoreError> {
          let local = self.store.fetch_assets(space, 0, u32::MAX)?;
          let mut local_versions: HashMap<i64, Option<i64>> = HashMap::with_capacity(local.len());
          for a in &local {
              local_versions.insert(a.id, a.server_version);
          }
          let limit = self.page_limit;
          let mut offset: u32 = 0;
          loop {
              let page = self.source.list_items(space, offset, limit).await?;
              let fetched = page.assets.len() as u32;
              let to_write: Vec<_> = page.assets.iter().filter(|a| match local_versions.get(&a.id) {
                  None => true,
                  Some(stored) => *stored != a.server_version,
              }).cloned().collect();
              if !to_write.is_empty() {
                  self.store.upsert_assets(&to_write)?;
                  for a in &to_write {
                      local_versions.insert(a.id, a.server_version);
                  }
              }
              if let Some(v) = page.assets.iter().filter_map(|a| a.server_version).max() {
                  self.store.set_highest_version(space, v)?;
              }
              offset += fetched;
              if fetched < limit {
                  break;
              }
          }
          self.store.set_reconcile_at(space, now_secs())?;
          self.store.crawl_progress(space)
      }
  }
  ```
  Note: `fetch_assets(space, 0, u32::MAX)` binds `u32::MAX as i64`, a valid large SQLite limit, returning the whole space to build the version index. Metadata-only and bounded by library size.
- [ ] Run-to-pass:
  ```
  cargo test -p sync-engine delta::tests
  ```
  Expected: `test result: ok. 4 passed`.
- [ ] Commit:
  ```
  git add core/sync-engine
  git commit -m "Add delta reconciliation keyed on server id and version"
  ```

---

### Task 31: Full persistence + sync-engine suite green (gate before facade wiring)

**Files**
- Test: no new files; runs the whole streams' suites together to catch cross-module regressions.

**Interfaces**
- Consumes: everything from Tasks 24 through 30.
- Produces: a green `cargo test` across both crates, the gate before Group A wires the facade (Tasks 33 through 38).

**Steps**

- [ ] Run the persistence suite:
  ```
  cargo test -p persistence
  ```
  Expected: `schema`, `assets`, `albums`, `sync_state` modules all `test result: ok`.
- [ ] Run the sync-engine suite:
  ```
  cargo test -p sync-engine
  ```
  Expected: `lib` (PageSource), `crawl`, and `delta` modules all `test result: ok`.
- [ ] Run both via the workspace target (if `synology-api`/`photoscore` are already implemented by the other stream, this covers the whole workspace; otherwise scope to the two crates):
  ```
  cargo test -p persistence -p sync-engine
  ```
  Expected: all green.
- [ ] Confirm no `taken_at`/`added_at` leaked into delta decisioning (guard that delta stays id/version-keyed):
  ```
  grep -n "taken_at\|added_at" core/sync-engine/src/delta.rs
  ```
  Expected: matches only inside the `#[cfg(test)]` helpers, none in the non-test reconcile logic.
- [ ] Commit (only if a lockfile or incidental change resulted):
  ```
  git add -A && git commit -m "Verify persistence and sync-engine suites pass together"
  ```

---

### Task 32: Scaffold the `PhotosCore` object, `Connection`/`Session` state, and `new` constructor

**Files**
- Modify: `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: `models` re-exports (Task 5), `persistence::Store` (Task 24).
- Produces: `#[uniffi::export]` re-export of every `models` type so Swift sees them under `PhotosCore`; `#[derive(uniffi::Object)] pub struct PhotosCore` holding interior-mutable `Store`, an optional post-login `ApiClient` state, config (`db_dir`, `cache_dir`); `#[uniffi::export] impl PhotosCore { #[uniffi::constructor] pub fn new(db_dir: String, cache_dir: String) -> Result<Arc<Self>, CoreError> }` (opens/creates SQLite + runs migrations; not async). The `FfiCrawlObserver` callback trait is also declared here.

**TDD steps**

- [ ] Write the failing test. Add to `core/photoscore/src/lib.rs`:
  ```rust
  #[cfg(test)]
  mod core_tests {
      use super::*;

      #[test]
      fn new_opens_store_and_reports_zero_counts() {
          let dir = std::env::temp_dir().join(format!("photoscore-test-{}", std::process::id()));
          std::fs::create_dir_all(&dir).unwrap();
          let db = dir.join("db").to_string_lossy().to_string();
          let cache = dir.join("cache").to_string_lossy().to_string();
          std::fs::create_dir_all(&db).unwrap();
          std::fs::create_dir_all(&cache).unwrap();
          let core = PhotosCore::new(db, cache).expect("core opens");
          assert_eq!(core.asset_count(models::Space::Personal).unwrap(), 0);
      }
  }
  ```
  (This test also exercises `asset_count`, added in Task 36; author Task 32's constructor first and let this test compile once Task 36 lands. To keep Task 32 self-contained and red-green honest, assert only construction here and move the `asset_count` assertion into Task 36. Task 32's test body is:)
  ```rust
  #[cfg(test)]
  mod core_tests {
      use super::*;

      #[test]
      fn new_opens_store() {
          let dir = std::env::temp_dir().join(format!("photoscore-new-{}", std::process::id()));
          let db = dir.join("db");
          let cache = dir.join("cache");
          std::fs::create_dir_all(&db).unwrap();
          std::fs::create_dir_all(&cache).unwrap();
          let _core = PhotosCore::new(db.to_string_lossy().into(), cache.to_string_lossy().into())
              .expect("core opens");
      }
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: compile error `cannot find type PhotosCore`.
- [ ] Minimal implementation. Extend `core/photoscore/src/lib.rs` (keep `setup_scaffolding!` and `core_version`):
  ```rust
  use std::sync::{Arc, Mutex};
  use models::{
      ApiCapability, Connection, CoreError, CrawlProgress, Session,
  };
  use persistence::Store;
  use synology_api::Transport;

  /// Implemented on the Swift side; called from Rust during crawl_space.
  #[uniffi::export(callback_interface)]
  pub trait FfiCrawlObserver: Send + Sync {
      fn on_progress(&self, progress: CrawlProgress);
  }

  /// Post-login connection state held inside the core.
  struct Live {
      transport: Transport,
      session: Session,
      connection: Connection,
      capabilities: Vec<ApiCapability>,
  }

  /// The single UniFFI-exported facade. Swift holds one instance per app run.
  #[derive(uniffi::Object)]
  pub struct PhotosCore {
      store: Store,
      cache_dir: String,
      live: Mutex<Option<Live>>,
  }

  #[uniffi::export(async_runtime = "tokio")]
  impl PhotosCore {
      /// Construct with a local DB directory. Opens/creates SQLite + runs migrations.
      #[uniffi::constructor]
      pub fn new(db_dir: String, cache_dir: String) -> Result<Arc<Self>, CoreError> {
          let db_path = std::path::Path::new(&db_dir).join("photos.sqlite");
          let store = Store::open_at(&db_path)?;
          Ok(Arc::new(PhotosCore { store, cache_dir, live: Mutex::new(None) }))
      }
  }
  ```
  Note: the `models` types already derive the UniFFI traits (Task 5). Because `photoscore` depends on `models` with those derives, UniFFI's `setup_scaffolding!` surfaces each type into the `PhotosCore` Swift module the moment an exported method signature references it. No explicit re-export is needed; the import list above holds only what Task 32 uses, and Tasks 33 through 37 widen it (`Asset`, `Album`, `MediaKind`, `SessionState`, `Space`, `ThumbnailData`, `ThumbnailSize`) as their signatures land.
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: `test result: ok. 1 passed`.
- [ ] Commit:
  ```
  git add core/photoscore/src/lib.rs
  git commit -m "Scaffold PhotosCore object with store-backed constructor and progress callback"
  ```

---

### Task 33: Implement `login` / `restore_session` / `sign_out` on `PhotosCore`

**Files**
- Modify: `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: `synology_api::{login, logout, build_client, Transport}` (Task 23), `PhotosCore` state (Task 32).
- Produces: `pub async fn login(&self, connection: Connection, username: String, password: String, otp_code: Option<String>) -> Result<Session, CoreError>` (builds a `Transport` for the connection, calls `synology_api::login`, stores `Live`); `pub async fn restore_session(&self, connection: Connection, session: Session) -> Result<SessionState, CoreError>` (rebuilds transport, validates with a cheap authed call, returns state); `pub async fn sign_out(&self) -> Result<(), CoreError>` (server logout, drops `Live`, clears per-account cache dir contents; idempotent).

**TDD steps**

- [ ] Write the failing test. Add a mock-server test that exercises login against a stubbed auth.cgi. Add to `core/photoscore/src/lib.rs` under `core_tests` (add `mockito` and `tokio` test macros to `[dev-dependencies]` of `core/photoscore/Cargo.toml` first: `mockito = "1"`, `tokio = { version = "1", features = ["rt-multi-thread","macros"] }`):
  ```rust
  #[tokio::test]
  async fn login_stores_live_session() {
      let mut server = mockito::Server::new_async().await;
      let _m = server.mock("GET", "/photo/webapi/auth.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"sid":"SID-CORE","synotoken":"TK"}}"#)
          .create_async().await;
      let dir = std::env::temp_dir().join(format!("photoscore-login-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
      let conn = models::Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
      let session = core.login(conn, "photouser".into(), "pw".into(), Some("123456".into())).await.expect("login ok");
      assert_eq!(session.sid, "SID-CORE");
  }

  #[tokio::test]
  async fn sign_out_is_idempotent_without_session() {
      let dir = std::env::temp_dir().join(format!("photoscore-signout-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
      core.sign_out().await.expect("sign_out without a session is a no-op");
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: compile error `no method named login found for struct PhotosCore`.
- [ ] Minimal implementation. Add methods inside the `#[uniffi::export(async_runtime = "tokio")] impl PhotosCore` block:
  ```rust
  pub async fn login(
      &self,
      connection: Connection,
      username: String,
      password: String,
      otp_code: Option<String>,
  ) -> Result<Session, CoreError> {
      let transport = Transport::new(&connection)?;
      let session = synology_api::login(&transport, &username, &password, otp_code.as_deref()).await?;
      let mut guard = self.live.lock().expect("live mutex poisoned");
      *guard = Some(Live {
          transport,
          session: session.clone(),
          connection,
          capabilities: Vec::new(),
      });
      Ok(session)
  }

  pub async fn restore_session(
      &self,
      connection: Connection,
      session: Session,
  ) -> Result<SessionState, CoreError> {
      let transport = Transport::new(&connection)?;
      // Validate with a cheap authed capability probe; auth failure => Expired.
      match synology_api::probe_capabilities(&transport).await {
          Ok(caps) => {
              let mut guard = self.live.lock().expect("live mutex poisoned");
              *guard = Some(Live { transport, session, connection, capabilities: caps });
              Ok(SessionState::Valid)
          }
          Err(CoreError::Auth { .. }) | Err(CoreError::OtpRequired) => Ok(SessionState::Expired),
          Err(other) => Err(other),
      }
  }

  pub async fn sign_out(&self) -> Result<(), CoreError> {
      let taken = {
          let mut guard = self.live.lock().expect("live mutex poisoned");
          guard.take()
      };
      if let Some(live) = taken {
          let _ = synology_api::logout(&live.transport, &live.session.sid).await;
      }
      // Clear the per-account thumbnail cache dir contents (read-only teardown).
      let thumbs = std::path::Path::new(&self.cache_dir).join("thumbs");
      if thumbs.exists() {
          let _ = std::fs::remove_dir_all(&thumbs);
      }
      Ok(())
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: the login and sign-out tests pass.
- [ ] Commit:
  ```
  git add core/photoscore/Cargo.toml core/photoscore/src/lib.rs
  git commit -m "Implement PhotosCore login, restore, and clean sign out"
  ```

---

### Task 34: Implement `probe_capabilities` on `PhotosCore`

**Files**
- Modify: `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: `synology_api::probe_capabilities` (Task 23), the `Live` state (Task 33).
- Produces: `pub async fn probe_capabilities(&self) -> Result<Vec<ApiCapability>, CoreError>` (requires a live session; probes, caches the set in `Live.capabilities`, returns it; `Auth` if not logged in).

**TDD steps**

- [ ] Write the failing test. Add to `core_tests`:
  ```rust
  #[tokio::test]
  async fn probe_capabilities_after_login_caches_and_returns() {
      let mut server = mockito::Server::new_async().await;
      let _login = server.mock("GET", "/photo/webapi/auth.cgi")
          .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
      let _info = server.mock("GET", "/photo/webapi/query.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":4}}}"#)
          .create_async().await;
      let dir = std::env::temp_dir().join(format!("photoscore-caps-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
      let conn = models::Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
      core.login(conn, "u".into(), "p".into(), None).await.unwrap();
      let caps = core.probe_capabilities().await.expect("probe ok");
      assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Browse.Item"));
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: compile error `no method named probe_capabilities`.
- [ ] Minimal implementation. Add inside the impl block:
  ```rust
  pub async fn probe_capabilities(&self) -> Result<Vec<ApiCapability>, CoreError> {
      let transport_and = {
          let guard = self.live.lock().expect("live mutex poisoned");
          match guard.as_ref() {
              Some(live) => Transport::new(&live.connection)?,
              None => return Err(CoreError::Auth { message: "not logged in".into() }),
          }
      };
      let caps = synology_api::probe_capabilities(&transport_and).await?;
      if let Some(live) = self.live.lock().expect("live mutex poisoned").as_mut() {
          live.capabilities = caps.clone();
      }
      Ok(caps)
  }
  ```
  Note: a fresh `Transport` is built from the stored `Connection` to avoid holding the mutex across the await. The cached capabilities feed version pinning in Tasks 35 through 37.
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: the probe test passes.
- [ ] Commit:
  ```
  git add core/photoscore/src/lib.rs
  git commit -m "Implement PhotosCore capability probe with cached versions"
  ```

---

### Task 35: Implement `crawl_space` (+ FfiCrawlObserver adapter), `reconcile_delta`, `crawl_progress`

**Files**
- Modify: `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: `sync_engine::{Crawler, DeltaReconciler, ProgressSink, PageSource, AssetPage}` (Tasks 28, 29, 30), `synology_api::{list_items, pin_version}` (Task 23), the `Live` state and cached capabilities (Task 34), `persistence::Store` (Task 27), `FfiCrawlObserver` (Task 32).
- Produces: a private `ApiPageSource` adapter implementing `PageSource` over `synology_api::list_items` for a fixed space/sid/transport/version; a private `ObserverSink` adapting `FfiCrawlObserver` onto `ProgressSink`; `pub async fn crawl_space(&self, space: Space, observer: Box<dyn FfiCrawlObserver>) -> Result<CrawlProgress, CoreError>`; `pub async fn reconcile_delta(&self, space: Space) -> Result<CrawlProgress, CoreError>`; `pub fn crawl_progress(&self, space: Space) -> Result<CrawlProgress, CoreError>` (local, no network).

**TDD steps**

- [ ] Write the failing test. Add to `core_tests`:
  ```rust
  #[tokio::test]
  async fn crawl_space_persists_and_reports_complete() {
      let mut server = mockito::Server::new_async().await;
      let _login = server.mock("GET", "/photo/webapi/auth.cgi")
          .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
      let _info = server.mock("GET", "/photo/webapi/query.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
          .create_async().await;
      let _list = server.mock("GET", "/photo/webapi/entry.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
          .create_async().await;
      let dir = std::env::temp_dir().join(format!("photoscore-crawl-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
      let conn = models::Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
      core.login(conn, "u".into(), "p".into(), None).await.unwrap();
      core.probe_capabilities().await.unwrap();

      struct Collector(std::sync::Mutex<Vec<models::CrawlProgress>>);
      impl FfiCrawlObserver for Collector {
          fn on_progress(&self, p: models::CrawlProgress) { self.0.lock().unwrap().push(p); }
      }
      let obs = Collector(std::sync::Mutex::new(vec![]));
      let final_p = core.crawl_space(models::Space::Personal, Box::new(obs)).await.expect("crawl ok");
      assert!(final_p.complete);
      assert_eq!(core.asset_count(models::Space::Personal).unwrap(), 1);
      assert!(core.crawl_progress(models::Space::Personal).unwrap().complete);
  }
  ```
  (The `Collector` cannot both be moved into `Box` and inspected afterward; assert via `crawl_progress`/`asset_count` on the core rather than the observer's buffer.)
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: compile error `no method named crawl_space`.
- [ ] Minimal implementation. Add adapters near the top of `core/photoscore/src/lib.rs` (module scope, not inside the impl):
  ```rust
  use sync_engine::{AssetPage, Crawler, DeltaReconciler, PageSource, ProgressSink};

  /// Adapts synology-api list_items into the sync-engine PageSource trait for one space.
  struct ApiPageSource {
      transport: Transport,
      sid: String,
      version: u32,
  }

  #[async_trait::async_trait]
  impl PageSource for ApiPageSource {
      async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
          let assets = synology_api::list_items(&self.transport, &self.sid, space, offset, limit, self.version).await?;
          // The Browse.Item list does not return a grand total on every DSM build; when
          // absent we treat a short page as the end. Report the running count as total so
          // the barrier still flips on the final short page (offset >= total holds).
          let total = if (assets.len() as u32) < limit {
              (offset as u64) + assets.len() as u64
          } else {
              (offset as u64) + limit as u64 + 1
          };
          Ok(AssetPage { assets, total })
      }
  }

  /// Adapts the UniFFI callback interface onto the sync-engine ProgressSink.
  struct ObserverSink {
      observer: Box<dyn FfiCrawlObserver>,
  }
  impl ProgressSink for ObserverSink {
      fn emit(&self, progress: CrawlProgress) {
          self.observer.on_progress(progress);
      }
  }
  ```
  Add `async_trait` to `core/photoscore/Cargo.toml` dependencies: `async-trait.workspace = true`. Then add these methods inside the impl block:
  ```rust
  pub async fn crawl_space(
      &self,
      space: Space,
      observer: Box<dyn FfiCrawlObserver>,
  ) -> Result<CrawlProgress, CoreError> {
      let source = self.page_source_for(space)?;
      let sink = ObserverSink { observer };
      let crawler = Crawler::new(&self.store, &source, 200);
      crawler.crawl_space(space, &sink).await
  }

  pub async fn reconcile_delta(&self, space: Space) -> Result<CrawlProgress, CoreError> {
      let source = self.page_source_for(space)?;
      let reconciler = DeltaReconciler::new(&self.store, &source, 200);
      reconciler.reconcile(space).await
  }

  pub fn crawl_progress(&self, space: Space) -> Result<CrawlProgress, CoreError> {
      self.store.crawl_progress(space)
  }
  ```
  And a private helper (in a plain `impl PhotosCore { ... }` block, not the exported one):
  ```rust
  impl PhotosCore {
      fn page_source_for(&self, _space: Space) -> Result<ApiPageSource, CoreError> {
          let guard = self.live.lock().expect("live mutex poisoned");
          let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
          let version = synology_api::pin_version(&live.capabilities, "SYNO.Foto.Browse.Item", 1)
              .or_else(|_| synology_api::pin_version(&live.capabilities, "SYNO.FotoTeam.Browse.Item", 1))
              .unwrap_or(1);
          Ok(ApiPageSource {
              transport: Transport::new(&live.connection)?,
              sid: live.session.sid.clone(),
              version,
          })
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: the crawl test passes.
- [ ] Commit:
  ```
  git add core/photoscore/Cargo.toml core/photoscore/src/lib.rs
  git commit -m "Implement PhotosCore crawl, delta reconcile, and progress readout"
  ```

---

### Task 36: Implement `fetch_assets` / `asset_count` / `fetch_albums` (local, no network)

**Files**
- Modify: `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: `persistence::Store` methods `fetch_assets`, `asset_count`, `fetch_albums` (Tasks 25, 26).
- Produces: `pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError>`; `pub fn asset_count(&self, space: Space) -> Result<u64, CoreError>`; `pub fn fetch_albums(&self, space: Space) -> Result<Vec<Album>, CoreError>`. All read local SQLite only.

**TDD steps**

- [ ] Write the failing test. Add to `core_tests`:
  ```rust
  #[test]
  fn fetch_assets_and_count_are_local_reads() {
      let dir = std::env::temp_dir().join(format!("photoscore-fetch-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
      assert_eq!(core.asset_count(models::Space::Personal).unwrap(), 0);
      assert!(core.fetch_assets(models::Space::Personal, 0, 10).unwrap().is_empty());
      assert!(core.fetch_albums(models::Space::Personal).unwrap().is_empty());
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore core_tests::fetch_assets_and_count_are_local_reads
  ```
  Expected: compile error `no method named fetch_assets`.
- [ ] Minimal implementation. Add inside the exported impl block:
  ```rust
  pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
      self.store.fetch_assets(space, offset, limit)
  }

  pub fn asset_count(&self, space: Space) -> Result<u64, CoreError> {
      self.store.asset_count(space)
  }

  pub fn fetch_albums(&self, space: Space) -> Result<Vec<Album>, CoreError> {
      self.store.fetch_albums(space)
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: all `core_tests` pass.
- [ ] Commit:
  ```
  git add core/photoscore/src/lib.rs
  git commit -m "Implement PhotosCore local windowed reads and counts"
  ```

---

### Task 37: Implement `thumbnail` (composite-key disk cache) and `download_original`

**Files**
- Modify: `core/photoscore/src/lib.rs`

**Interfaces**
- Consumes: `synology_api::{fetch_thumbnail, download_original, pin_version}` (Task 23), the `Live` state (Task 34), `models::{ThumbnailData, ThumbnailSize}`.
- Produces: `pub async fn thumbnail(&self, space: Space, asset_id: i64, cache_key: String, size: ThumbnailSize) -> Result<ThumbnailData, CoreError>` (composite disk cache at `{cache_dir}/thumbs/{space}/{server_id}/{size}_{cache_key}.jpg`; returns cached path + bytes; a changed cache_key yields a new path); `pub async fn download_original(&self, space: Space, asset_id: i64, cache_key: String) -> Result<String, CoreError>` (downloads to a temp file, returns the absolute path; read-only).

**TDD steps**

- [ ] Write the failing test. Add to `core_tests`:
  ```rust
  #[tokio::test]
  async fn thumbnail_caches_to_composite_path() {
      let mut server = mockito::Server::new_async().await;
      let _login = server.mock("GET", "/photo/webapi/auth.cgi")
          .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
      let _info = server.mock("GET", "/photo/webapi/query.cgi")
          .with_status(200)
          .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
          .create_async().await;
      let _thumb = server.mock("GET", "/photo/webapi/entry.cgi")
          .with_status(200).with_header("content-type", "image/jpeg")
          .with_body(vec![0xFF, 0xD8, 0xFF]).create_async().await;
      let dir = std::env::temp_dir().join(format!("photoscore-thumb-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
      let conn = models::Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
      core.login(conn, "u".into(), "p".into(), None).await.unwrap();
      core.probe_capabilities().await.unwrap();
      let data = core.thumbnail(models::Space::Personal, 101, "CK1".into(), models::ThumbnailSize::Sm).await.expect("thumb ok");
      assert!(data.cached_path.contains("thumbs"));
      assert!(data.cached_path.ends_with("sm_CK1.jpg"));
      assert!(std::path::Path::new(&data.cached_path).exists());
      assert_eq!(data.bytes, vec![0xFF, 0xD8, 0xFF]);
  }
  ```
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore core_tests::thumbnail_caches_to_composite_path
  ```
  Expected: compile error `no method named thumbnail`.
- [ ] Minimal implementation. Add inside the exported impl block:
  ```rust
  pub async fn thumbnail(
      &self,
      space: Space,
      asset_id: i64,
      cache_key: String,
      size: ThumbnailSize,
  ) -> Result<ThumbnailData, CoreError> {
      let size_tag = match size { ThumbnailSize::Sm => "sm", ThumbnailSize::M => "m", ThumbnailSize::Xl => "xl" };
      let space_tag = match space { Space::Personal => "0", Space::Shared => "1" };
      let dir = std::path::Path::new(&self.cache_dir).join("thumbs").join(space_tag).join(asset_id.to_string());
      let path = dir.join(format!("{size_tag}_{cache_key}.jpg"));
      if path.exists() {
          let bytes = std::fs::read(&path).map_err(|e| CoreError::Storage { message: e.to_string() })?;
          return Ok(ThumbnailData { cached_path: path.to_string_lossy().into(), bytes });
      }
      let (transport, sid, version) = {
          let guard = self.live.lock().expect("live mutex poisoned");
          let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
          let api = match space { Space::Personal => "SYNO.Foto.Thumbnail", Space::Shared => "SYNO.FotoTeam.Thumbnail" };
          let version = synology_api::pin_version(&live.capabilities, api, 2).unwrap_or(2);
          (Transport::new(&live.connection)?, live.session.sid.clone(), version)
      };
      let bytes = synology_api::fetch_thumbnail(&transport, &sid, space, asset_id, &cache_key, size, version).await?;
      std::fs::create_dir_all(&dir).map_err(|e| CoreError::Storage { message: e.to_string() })?;
      std::fs::write(&path, &bytes).map_err(|e| CoreError::Storage { message: e.to_string() })?;
      Ok(ThumbnailData { cached_path: path.to_string_lossy().into(), bytes })
  }

  pub async fn download_original(
      &self,
      space: Space,
      asset_id: i64,
      cache_key: String,
  ) -> Result<String, CoreError> {
      let (transport, sid, version) = {
          let guard = self.live.lock().expect("live mutex poisoned");
          let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
          let api = match space { Space::Personal => "SYNO.Foto.Download", Space::Shared => "SYNO.FotoTeam.Download" };
          let version = synology_api::pin_version(&live.capabilities, api, 2).unwrap_or(2);
          (Transport::new(&live.connection)?, live.session.sid.clone(), version)
      };
      let bytes = synology_api::download_original(&transport, &sid, space, asset_id, &cache_key, version).await?;
      let tmp = std::env::temp_dir().join(format!("syno-orig-{asset_id}-{cache_key}"));
      std::fs::write(&tmp, &bytes).map_err(|e| CoreError::Storage { message: e.to_string() })?;
      Ok(tmp.to_string_lossy().into())
  }
  ```
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore core_tests
  ```
  Expected: the thumbnail test passes; all `core_tests` green.
- [ ] Commit:
  ```
  git add core/photoscore/src/lib.rs
  git commit -m "Implement PhotosCore thumbnail disk cache and original download"
  ```

---

### Task 38: Regenerate bindings, rebuild xcframework, run cross-boundary integration smoke test

**Files**
- Modify (regenerated): `bindings/PhotosCore.swift`, `bindings/PhotosCoreFFI.h`, `bindings/module.modulemap`
- Create: `core/photoscore/tests/boundary_smoke.rs`

**Interfaces**
- Consumes: the full `PhotosCore` impl (Tasks 32 through 37).
- Produces: regenerated Swift bindings exposing the full `PhotosCore` object, its methods (contract 2.5), the `CoreError` Swift enum, and the `FfiCrawlObserver` protocol; a rebuilt xcframework; a Rust-side smoke test proving the whole surface compiles and the workspace builds for the device target. After this task the real xcframework replaces the Swift-side mock in Group D.

**TDD steps**

- [ ] Write the failing verification. Author `core/photoscore/tests/boundary_smoke.rs` that instantiates the core through the public constructor (proves the exported surface is usable from an external crate the way UniFFI scaffolding is):
  ```rust
  use photoscore::PhotosCore;

  #[test]
  fn public_constructor_is_reachable() {
      let dir = std::env::temp_dir().join(format!("photoscore-boundary-{}", std::process::id()));
      std::fs::create_dir_all(dir.join("db")).unwrap();
      std::fs::create_dir_all(dir.join("cache")).unwrap();
      let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into())
          .expect("core constructs");
      assert_eq!(core.asset_count(models::Space::Personal).unwrap(), 0);
  }
  ```
  Add `models = { path = "../models" }` to `core/photoscore/Cargo.toml` dev-dependencies if the test needs the `Space` type directly (it already depends on `models` as a normal dep, so `models::Space` resolves). Then verify the bindings currently only expose `coreVersion` (failing pre-state):
  ```
  grep -q "class PhotosCore" bindings/PhotosCore.swift && echo HAS_CLASS || echo NO_CLASS
  ```
  Expected: `NO_CLASS` (the committed bindings from Task 7 predate the object).
- [ ] Run-to-fail:
  ```
  cargo test -p photoscore --test boundary_smoke
  ```
  Expected: passes if the surface compiles; if a method signature drifted from the contract, this is where it surfaces as a compile error. The binding-regeneration failure is the `NO_CLASS` state above.
- [ ] Minimal implementation. Regenerate the bindings and rebuild the framework:
  ```
  make bindings && make xcframework
  ```
  This overwrites `bindings/PhotosCore.swift` with the full object surface. No hand edits.
- [ ] Run-to-pass:
  ```
  cargo test -p photoscore --test boundary_smoke
  cd /Users/sahil/code/github/synology-native-photos && make test-rust 2>&1 | tail -15
  grep -q "class PhotosCore" bindings/PhotosCore.swift && echo HAS_CLASS || echo NO_CLASS
  grep -q "func fetchAssets" bindings/PhotosCore.swift && grep -q "protocol FfiCrawlObserver" bindings/PhotosCore.swift && echo SURFACE_OK || echo SURFACE_MISSING
  ```
  Expected: boundary smoke passes; `make test-rust` reports the whole workspace green; `HAS_CLASS`; `SURFACE_OK`.
- [ ] Commit:
  ```
  cd /Users/sahil/code/github/synology-native-photos
  git add bindings/ core/photoscore/Cargo.toml core/photoscore/tests/boundary_smoke.rs
  git commit -m "Regenerate Swift bindings for the full PhotosCore surface and verify the workspace builds"
  ```

---

### Task 39: Core abstraction protocol + `FakePhotosCore` test double

The Swift app builds against `bindings/PhotosCore.swift` (frozen at Task 7, fully populated at Task 38) through a protocol seam so the whole app compiles and its tests pass before and after the real xcframework lands. The protocol mirrors the generated method names exactly (contract 2.5). Swift unit tests use Swift Testing (`import Testing`).

**Files**
- Create: `app/SynologyPhotos/CoreBridge/PhotosCoreProtocol.swift`
- Create: `app/SynologyPhotosTests/FakePhotosCore.swift`
- Create: `app/SynologyPhotosTests/FakePhotosCoreTests.swift`

**Interfaces**
- Consumes (from `bindings/PhotosCore.swift`): `Connection`, `Session`, `SessionState`, `Asset`, `Album`, `CrawlProgress`, `ApiCapability`, `ThumbnailData`, `ThumbnailSize`, `Space`, `CoreError`, `FfiCrawlObserver`.
- Produces: `protocol PhotosCoreProtocol` with the async-throws methods matching contract 2.5, `extension PhotosCore: PhotosCoreProtocol {}`, and `final class FakePhotosCore: PhotosCoreProtocol`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/FakePhotosCoreTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  struct FakePhotosCoreTests {
      @Test func fakeLoginReturnsConfiguredSession() async throws {
          let fake = FakePhotosCore()
          fake.loginResult = .success(Session(sid: "SID123", synoToken: nil, username: "photo", deviceDid: nil))
          let conn = Connection(host: "https://192.168.1.10:5001", verifyTls: true, pinnedCertDer: nil)
          let session = try await fake.login(connection: conn, username: "photo", password: "pw", otpCode: nil)
          #expect(session.sid == "SID123")
          #expect(fake.loginCallCount == 1)
      }

      @Test func fakeLoginThrowsOtpRequired() async {
          let fake = FakePhotosCore()
          fake.loginResult = .failure(CoreError.OtpRequired)
          let conn = Connection(host: "https://x:5001", verifyTls: true, pinnedCertDer: nil)
          await #expect(throws: CoreError.self) {
              _ = try await fake.login(connection: conn, username: "u", password: "p", otpCode: nil)
          }
      }

      @Test func fakeFetchAssetsReturnsWindow() throws {
          let fake = FakePhotosCore()
          fake.assets[.personal] = (0..<100).map { Self.asset(id: Int64($0)) }
          let window = try fake.fetchAssets(space: .personal, offset: 10, limit: 5)
          #expect(window.count == 5)
          #expect(window.first?.id == 10)
      }

      static func asset(id: Int64) -> Asset {
          Asset(id: id, cacheKey: "ck\(id)", filename: "IMG_\(id).jpg", mediaKind: .photo,
                takenAt: 1_700_000_000 + id, addedAt: nil, width: 4032, height: 3024,
                fileSize: nil, space: .personal, serverVersion: id)
      }
  }
  ```
  Regenerate the project so the new files are in the test target:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodegen generate
  ```
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/FakePhotosCoreTests 2>&1 | tail -30
  ```
  Expected: compile failure `cannot find 'FakePhotosCore' in scope` / `cannot find type 'PhotosCoreProtocol'`.
- [ ] Minimal implementation `app/SynologyPhotos/CoreBridge/PhotosCoreProtocol.swift`:
  ```swift
  import Foundation
  import PhotosCore

  /// The subset of the generated PhotosCore object that the app consumes.
  /// Method names/signatures mirror contract section 2.5 exactly so the real
  /// UniFFI-generated PhotosCore conforms without adaptation.
  public protocol PhotosCoreProtocol: AnyObject, Sendable {
      func login(connection: Connection, username: String, password: String, otpCode: String?) async throws -> Session
      func restoreSession(connection: Connection, session: Session) async throws -> SessionState
      func signOut() async throws
      func probeCapabilities() async throws -> [ApiCapability]
      func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress
      func reconcileDelta(space: Space) async throws -> CrawlProgress
      func crawlProgress(space: Space) throws -> CrawlProgress
      func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset]
      func assetCount(space: Space) throws -> UInt64
      func fetchAlbums(space: Space) throws -> [Album]
      func thumbnail(space: Space, assetId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData
      func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String
  }

  /// The real generated object conforms once the xcframework is linked (Task 38).
  extension PhotosCore: PhotosCoreProtocol {}
  ```
  And `app/SynologyPhotosTests/FakePhotosCore.swift`:
  ```swift
  import Foundation
  import PhotosCore
  @testable import SynologyPhotos

  /// Deterministic in-memory test double conforming to PhotosCoreProtocol.
  final class FakePhotosCore: PhotosCoreProtocol, @unchecked Sendable {
      var loginResult: Result<Session, CoreError> = .success(
          Session(sid: "FAKE", synoToken: nil, username: "photo", deviceDid: nil))
      var restoreResult: Result<SessionState, CoreError> = .success(.valid)
      var capabilities: [ApiCapability] = []
      var assets: [Space: [Asset]] = [:]
      var albums: [Space: [Album]] = [:]
      var crawlFinal: [Space: CrawlProgress] = [:]
      var progressByspace: [Space: CrawlProgress] = [:]
      var thumbnailResult: Result<ThumbnailData, CoreError> =
          .success(ThumbnailData(cachedPath: "/tmp/fake.jpg", bytes: []))
      var downloadResult: Result<String, CoreError> = .success("/tmp/original.jpg")
      var crawlProgressToEmit: [CrawlProgress] = []

      private(set) var loginCallCount = 0
      private(set) var signOutCallCount = 0
      private(set) var lastOtpCode: String??

      func login(connection: Connection, username: String, password: String, otpCode: String?) async throws -> Session {
          loginCallCount += 1
          lastOtpCode = .some(otpCode)
          return try loginResult.get()
      }
      func restoreSession(connection: Connection, session: Session) async throws -> SessionState { try restoreResult.get() }
      func signOut() async throws { signOutCallCount += 1 }
      func probeCapabilities() async throws -> [ApiCapability] { capabilities }
      func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress {
          for p in crawlProgressToEmit { observer.onProgress(progress: p) }
          return crawlFinal[space] ?? CrawlProgress(space: space, done: 0, total: 0, complete: true)
      }
      func reconcileDelta(space: Space) async throws -> CrawlProgress {
          crawlFinal[space] ?? CrawlProgress(space: space, done: 0, total: 0, complete: true)
      }
      func crawlProgress(space: Space) throws -> CrawlProgress {
          progressByspace[space] ?? CrawlProgress(space: space, done: 0, total: 0, complete: false)
      }
      func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
          let all = assets[space] ?? []
          let start = Int(offset)
          guard start < all.count else { return [] }
          let end = min(start + Int(limit), all.count)
          return Array(all[start..<end])
      }
      func assetCount(space: Space) throws -> UInt64 { UInt64((assets[space] ?? []).count) }
      func fetchAlbums(space: Space) throws -> [Album] { albums[space] ?? [] }
      func thumbnail(space: Space, assetId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData {
          try thumbnailResult.get()
      }
      func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String {
          try downloadResult.get()
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/FakePhotosCoreTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'FakePhotosCoreTests' passed`, 3 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add PhotosCore protocol seam and in-memory fake for app tests"
  ```

---

### Task 40: `PhotosCoreClient` actor + `CoreError+Swift` mapping

**Files**
- Create: `app/SynologyPhotos/CoreBridge/PhotosCoreClient.swift`
- Create: `app/SynologyPhotos/CoreBridge/CoreError+Swift.swift`
- Create: `app/SynologyPhotosTests/PhotosCoreClientTests.swift`

**Interfaces**
- Consumes: `PhotosCoreProtocol` (Task 39), `CoreError` (contract 2.2).
- Produces: `actor PhotosCoreClient` with `init(core: PhotosCoreProtocol)` and pass-through methods for the whole surface; `extension CoreError { var userMessage: String; var isRetryable: Bool }`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/PhotosCoreClientTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  struct PhotosCoreClientTests {
      @Test func clientForwardsLogin() async throws {
          let fake = FakePhotosCore()
          fake.loginResult = .success(Session(sid: "S", synoToken: "T", username: "photo", deviceDid: nil))
          let client = PhotosCoreClient(core: fake)
          let conn = Connection(host: "https://h:5001", verifyTls: true, pinnedCertDer: nil)
          let s = try await client.login(connection: conn, username: "photo", password: "pw", otpCode: "123456")
          #expect(s.synoToken == "T")
          #expect(fake.lastOtpCode == .some(.some("123456")))
      }

      @Test func otpRequiredMapsToPrompt() {
          #expect(CoreError.OtpRequired.userMessage.localizedCaseInsensitiveContains("code"))
          #expect(CoreError.OtpRequired.isRetryable == false)
      }

      @Test func networkErrorIsRetryable() {
          let e = CoreError.Network(message: "timeout")
          #expect(e.isRetryable == true)
          #expect(e.userMessage.localizedCaseInsensitiveContains("network"))
      }

      @Test func writeRefusedHasSafeMessage() {
          #expect(CoreError.WriteRefused.userMessage.localizedCaseInsensitiveContains("read-only"))
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/PhotosCoreClientTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'PhotosCoreClient' in scope` and `value of type 'CoreError' has no member 'userMessage'`.
- [ ] Minimal implementation `app/SynologyPhotos/CoreBridge/CoreError+Swift.swift`:
  ```swift
  import Foundation
  import PhotosCore

  extension CoreError {
      /// Human-facing message for the UI. Never leaks raw server text unfiltered.
      var userMessage: String {
          switch self {
          case .Auth(let message): return "Sign in failed. \(message)"
          case .OtpRequired: return "Enter your two-factor code to continue."
          case .Network(let message): return "Network problem. \(message)"
          case .Decode(let message): return "The server sent something we could not read. \(message)"
          case .UnexpectedResponse(let message): return "Unexpected response from the NAS. \(message)"
          case .WriteRefused: return "This action was blocked. The app is in read-only mode."
          case .Storage(let message): return "Local storage problem. \(message)"
          case .CapabilityUnavailable(let api): return "Your NAS does not offer a required feature: \(api)."
          }
      }

      /// Whether a retry could plausibly succeed without user action.
      var isRetryable: Bool {
          switch self {
          case .Network: return true
          default: return false
          }
      }
  }
  ```
  And `app/SynologyPhotos/CoreBridge/PhotosCoreClient.swift`:
  ```swift
  import Foundation
  import PhotosCore

  /// Serializes all access to the single PhotosCore instance for the app run.
  /// Every method rethrows CoreError verbatim; callers map via userMessage.
  actor PhotosCoreClient {
      private let core: PhotosCoreProtocol
      init(core: PhotosCoreProtocol) { self.core = core }

      func login(connection: Connection, username: String, password: String, otpCode: String?) async throws -> Session {
          try await core.login(connection: connection, username: username, password: password, otpCode: otpCode)
      }
      func restoreSession(connection: Connection, session: Session) async throws -> SessionState {
          try await core.restoreSession(connection: connection, session: session)
      }
      func signOut() async throws { try await core.signOut() }
      func probeCapabilities() async throws -> [ApiCapability] { try await core.probeCapabilities() }
      func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress {
          try await core.crawlSpace(space: space, observer: observer)
      }
      func reconcileDelta(space: Space) async throws -> CrawlProgress { try await core.reconcileDelta(space: space) }
      func crawlProgress(space: Space) throws -> CrawlProgress { try core.crawlProgress(space: space) }
      func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
          try core.fetchAssets(space: space, offset: offset, limit: limit)
      }
      func assetCount(space: Space) throws -> UInt64 { try core.assetCount(space: space) }
      func fetchAlbums(space: Space) throws -> [Album] { try core.fetchAlbums(space: space) }
      func thumbnail(space: Space, assetId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData {
          try await core.thumbnail(space: space, assetId: assetId, cacheKey: cacheKey, size: size)
      }
      func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String {
          try await core.downloadOriginal(space: space, assetId: assetId, cacheKey: cacheKey)
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/PhotosCoreClientTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'PhotosCoreClientTests' passed`, 4 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add PhotosCoreClient actor and CoreError user-facing mapping"
  ```

---

### Task 41: `KeychainSID` store/load/clear

**Files**
- Create: `app/SynologyPhotos/Auth/KeychainSID.swift`
- Create: `app/SynologyPhotosTests/KeychainSIDTests.swift`

**Interfaces**
- Consumes: `Session` (contract 2.1), Security framework.
- Produces: `struct StoredSession: Codable, Equatable { let sid, synoToken?, username, deviceDid?, host }`; `enum KeychainSID` with `save(_ session: Session, host: String) throws`, `load(host:username:) throws -> StoredSession?`, `clear(host:username:) throws`, `clearAll() throws`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/KeychainSIDTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  struct KeychainSIDTests {
      private let host = "https://kc-test.local:5001"
      private let user = "kctestuser"
      private func cleanup() { try? KeychainSID.clear(host: host, username: user) }

      @Test func saveThenLoadRoundTrips() throws {
          cleanup(); defer { cleanup() }
          let s = Session(sid: "SID-ABC", synoToken: "TOK", username: user, deviceDid: "DID9")
          try KeychainSID.save(s, host: host)
          let loaded = try KeychainSID.load(host: host, username: user)
          #expect(loaded?.sid == "SID-ABC")
          #expect(loaded?.synoToken == "TOK")
          #expect(loaded?.deviceDid == "DID9")
          #expect(loaded?.host == host)
      }

      @Test func saveOverwritesExisting() throws {
          cleanup(); defer { cleanup() }
          try KeychainSID.save(Session(sid: "OLD", synoToken: nil, username: user, deviceDid: nil), host: host)
          try KeychainSID.save(Session(sid: "NEW", synoToken: nil, username: user, deviceDid: nil), host: host)
          #expect(try KeychainSID.load(host: host, username: user)?.sid == "NEW")
      }

      @Test func clearRemovesEntry() throws {
          try KeychainSID.save(Session(sid: "X", synoToken: nil, username: user, deviceDid: nil), host: host)
          try KeychainSID.clear(host: host, username: user)
          #expect(try KeychainSID.load(host: host, username: user) == nil)
      }

      @Test func loadMissingReturnsNil() throws {
          cleanup()
          #expect(try KeychainSID.load(host: host, username: "nobody") == nil)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/KeychainSIDTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'KeychainSID' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Auth/KeychainSID.swift`:
  ```swift
  import Foundation
  import Security
  import PhotosCore

  struct StoredSession: Codable, Equatable {
      let sid: String
      let synoToken: String?
      let username: String
      let deviceDid: String?
      let host: String
  }

  enum KeychainError: Error { case unexpectedStatus(OSStatus), encodeFailed, decodeFailed }

  /// Session persistence in the macOS Keychain, keyed per (host, username).
  /// Generic-password item; access limited to when the device is unlocked.
  enum KeychainSID {
      private static let service = "com.synologynativephotos.session"
      private static func account(host: String, username: String) -> String { "\(host)|\(username)" }

      static func save(_ session: Session, host: String) throws {
          let stored = StoredSession(sid: session.sid, synoToken: session.synoToken,
                                     username: session.username, deviceDid: session.deviceDid, host: host)
          guard let data = try? JSONEncoder().encode(stored) else { throw KeychainError.encodeFailed }
          let acct = account(host: host, username: session.username)
          let query: [String: Any] = [
              kSecClass as String: kSecClassGenericPassword,
              kSecAttrService as String: service,
              kSecAttrAccount as String: acct,
          ]
          SecItemDelete(query as CFDictionary)
          var add = query
          add[kSecValueData as String] = data
          add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
          let status = SecItemAdd(add as CFDictionary, nil)
          guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
      }

      static func load(host: String, username: String) throws -> StoredSession? {
          let query: [String: Any] = [
              kSecClass as String: kSecClassGenericPassword,
              kSecAttrService as String: service,
              kSecAttrAccount as String: account(host: host, username: username),
              kSecReturnData as String: true,
              kSecMatchLimit as String: kSecMatchLimitOne,
          ]
          var out: CFTypeRef?
          let status = SecItemCopyMatching(query as CFDictionary, &out)
          if status == errSecItemNotFound { return nil }
          guard status == errSecSuccess, let data = out as? Data else { throw KeychainError.unexpectedStatus(status) }
          guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else { throw KeychainError.decodeFailed }
          return stored
      }

      static func clear(host: String, username: String) throws {
          let query: [String: Any] = [
              kSecClass as String: kSecClassGenericPassword,
              kSecAttrService as String: service,
              kSecAttrAccount as String: account(host: host, username: username),
          ]
          let status = SecItemDelete(query as CFDictionary)
          guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
      }

      static func clearAll() throws {
          let query: [String: Any] = [
              kSecClass as String: kSecClassGenericPassword,
              kSecAttrService as String: service,
          ]
          let status = SecItemDelete(query as CFDictionary)
          guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/KeychainSIDTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'KeychainSIDTests' passed`, 4 tests. Keychain access needs the app target's signing and a login keychain; on a headless CI without one, these are the tests to skip and run on the local Mac.
- [ ] Commit:
  ```
  git add app && git commit -m "Store session SID in Keychain keyed per host and account"
  ```

---

### Task 42: `AuthStateMachine` (valid/expired/invalid + 2FA)

**Files**
- Create: `app/SynologyPhotos/Auth/AuthStateMachine.swift`
- Create: `app/SynologyPhotosTests/AuthStateMachineTests.swift`

**Interfaces**
- Consumes: `PhotosCoreClient` (Task 40), `KeychainSID` (Task 41), `Connection`, `Session`, `SessionState`, `CoreError`.
- Produces: `enum AuthPhase: Equatable { case loggedOut; case authenticating; case needsOtp(username:); case restoring; case valid(Session); case expired; case invalid(message:) }`; `@MainActor @Observable final class AuthStateMachine` with `var phase`, `init(client:)`, `func attemptLogin(host:username:password:otpCode:pinnedCertDer:) async`, `func restore(host:username:) async`, `func markExpired()`, `func reset()`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/AuthStateMachineTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct AuthStateMachineTests {
      @Test func successfulLoginBecomesValid() async {
          let fake = FakePhotosCore()
          fake.loginResult = .success(Session(sid: "S1", synoToken: nil, username: "photo", deviceDid: nil))
          let sm = AuthStateMachine(client: PhotosCoreClient(core: fake))
          await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: nil, pinnedCertDer: nil)
          guard case .valid(let s) = sm.phase else { Issue.record("expected valid, got \(sm.phase)"); return }
          #expect(s.sid == "S1")
      }

      @Test func otpRequiredMovesToNeedsOtp() async {
          let fake = FakePhotosCore()
          fake.loginResult = .failure(.OtpRequired)
          let sm = AuthStateMachine(client: PhotosCoreClient(core: fake))
          await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: nil, pinnedCertDer: nil)
          #expect(sm.phase == .needsOtp(username: "photo"))
      }

      @Test func badCredentialsBecomesInvalid() async {
          let fake = FakePhotosCore()
          fake.loginResult = .failure(.Auth(message: "no such account"))
          let sm = AuthStateMachine(client: PhotosCoreClient(core: fake))
          await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "bad", otpCode: nil, pinnedCertDer: nil)
          guard case .invalid = sm.phase else { Issue.record("expected invalid, got \(sm.phase)"); return }
      }

      @Test func otpRetryWithCodeSucceeds() async {
          let fake = FakePhotosCore()
          fake.loginResult = .failure(.OtpRequired)
          let sm = AuthStateMachine(client: PhotosCoreClient(core: fake))
          await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: nil, pinnedCertDer: nil)
          #expect(sm.phase == .needsOtp(username: "photo"))
          fake.loginResult = .success(Session(sid: "S2", synoToken: nil, username: "photo", deviceDid: "DID"))
          await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: "654321", pinnedCertDer: nil)
          guard case .valid = sm.phase else { Issue.record("expected valid, got \(sm.phase)"); return }
      }

      @Test func restoreExpiredMarksExpired() async {
          let fake = FakePhotosCore()
          fake.restoreResult = .success(.expired)
          let sm = AuthStateMachine(client: PhotosCoreClient(core: fake))
          try? KeychainSID.save(Session(sid: "OLD", synoToken: nil, username: "restuser", deviceDid: nil), host: "https://h:5001")
          defer { try? KeychainSID.clear(host: "https://h:5001", username: "restuser") }
          await sm.restore(host: "https://h:5001", username: "restuser")
          #expect(sm.phase == .expired)
      }

      @Test func resetReturnsToLoggedOut() async {
          let sm = AuthStateMachine(client: PhotosCoreClient(core: FakePhotosCore()))
          sm.markExpired()
          #expect(sm.phase == .expired)
          sm.reset()
          #expect(sm.phase == .loggedOut)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/AuthStateMachineTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'AuthStateMachine' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Auth/AuthStateMachine.swift`:
  ```swift
  import Foundation
  import PhotosCore

  enum AuthPhase: Equatable {
      case loggedOut
      case authenticating
      case needsOtp(username: String)
      case restoring
      case valid(Session)
      case expired
      case invalid(message: String)

      static func == (l: AuthPhase, r: AuthPhase) -> Bool {
          switch (l, r) {
          case (.loggedOut, .loggedOut), (.authenticating, .authenticating),
               (.restoring, .restoring), (.expired, .expired): return true
          case let (.needsOtp(a), .needsOtp(b)): return a == b
          case let (.valid(a), .valid(b)): return a.sid == b.sid
          case let (.invalid(a), .invalid(b)): return a == b
          default: return false
          }
      }
  }

  @MainActor
  @Observable
  final class AuthStateMachine {
      private let client: PhotosCoreClient
      var phase: AuthPhase = .loggedOut
      init(client: PhotosCoreClient) { self.client = client }

      /// Attempt a login. On OtpRequired, transition to needsOtp so the view
      /// re-prompts and re-calls with an otpCode (2FA is always on, contract).
      func attemptLogin(host: String, username: String, password: String,
                        otpCode: String?, pinnedCertDer: [UInt8]?) async {
          phase = .authenticating
          let conn = Connection(host: host, verifyTls: true, pinnedCertDer: pinnedCertDer)
          do {
              let session = try await client.login(connection: conn, username: username,
                                                   password: password, otpCode: otpCode)
              try? KeychainSID.save(session, host: host)
              phase = .valid(session)
          } catch let e as CoreError {
              switch e {
              case .OtpRequired: phase = .needsOtp(username: username)
              case .Auth(let message): phase = .invalid(message: message)
              default: phase = .invalid(message: e.userMessage)
              }
          } catch {
              phase = .invalid(message: error.localizedDescription)
          }
      }

      /// Restore from a stored SID without re-prompting credentials.
      func restore(host: String, username: String) async {
          guard let stored = try? KeychainSID.load(host: host, username: username), let s = stored else {
              phase = .loggedOut
              return
          }
          phase = .restoring
          let session = Session(sid: s.sid, synoToken: s.synoToken, username: s.username, deviceDid: s.deviceDid)
          let conn = Connection(host: host, verifyTls: true, pinnedCertDer: nil)
          do {
              let state = try await client.restoreSession(connection: conn, session: session)
              switch state {
              case .valid: phase = .valid(session)
              case .expired: phase = .expired
              case .invalid: phase = .invalid(message: "Stored session is no longer valid.")
              }
          } catch let e as CoreError {
              phase = e.isRetryable ? .expired : .invalid(message: e.userMessage)
          } catch {
              phase = .expired
          }
      }

      func markExpired() { phase = .expired }
      func reset() { phase = .loggedOut }
  }
  ```
  Note: `verifyTls` stays `true` in both login paths; a pinned DER is passed only for the Tailscale name (via Task 44's `HostSelector`), never by disabling verification.
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/AuthStateMachineTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'AuthStateMachineTests' passed`, 6 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add auth state machine covering valid, expired, invalid and 2FA phases"
  ```

---

### Task 43: `LoginView` (host/user/pass/OTP form)

**Files**
- Create: `app/SynologyPhotos/Auth/LoginView.swift`
- Create: `app/SynologyPhotosTests/LoginViewModelTests.swift`

**Interfaces**
- Consumes: `AuthStateMachine` (Task 42), `AuthPhase`.
- Produces: `struct LoginView: View { init(auth: AuthStateMachine) }`; `@MainActor @Observable final class LoginFormModel` with `var host/username/password/otpCode`, `var showOtp/isBusy`, `var errorText: String?`, `func submit() async`, `func sync(with phase: AuthPhase)`. A11y identifiers `login.host/username/password/otp/submit/error`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/LoginViewModelTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct LoginViewModelTests {
      @Test func syncShowsOtpFieldOnNeedsOtp() {
          let m = LoginFormModel(auth: AuthStateMachine(client: PhotosCoreClient(core: FakePhotosCore())))
          m.sync(with: .needsOtp(username: "photo"))
          #expect(m.showOtp == true)
          #expect(m.errorText?.localizedCaseInsensitiveContains("code") == true)
      }

      @Test func syncShowsErrorOnInvalid() {
          let m = LoginFormModel(auth: AuthStateMachine(client: PhotosCoreClient(core: FakePhotosCore())))
          m.sync(with: .invalid(message: "bad password"))
          #expect(m.errorText == "bad password")
          #expect(m.showOtp == false)
      }

      @Test func syncClearsErrorOnValid() {
          let m = LoginFormModel(auth: AuthStateMachine(client: PhotosCoreClient(core: FakePhotosCore())))
          m.errorText = "stale"
          m.sync(with: .valid(Session(sid: "S", synoToken: nil, username: "photo", deviceDid: nil)))
          #expect(m.errorText == nil)
      }

      @Test func submitForwardsOtpCode() async {
          let fake = FakePhotosCore()
          fake.loginResult = .success(Session(sid: "S", synoToken: nil, username: "photo", deviceDid: nil))
          let auth = AuthStateMachine(client: PhotosCoreClient(core: fake))
          let m = LoginFormModel(auth: auth)
          m.host = "https://h:5001"; m.username = "photo"; m.password = "pw"; m.showOtp = true; m.otpCode = "111222"
          await m.submit()
          #expect(fake.lastOtpCode == .some(.some("111222")))
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/LoginViewModelTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'LoginFormModel' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Auth/LoginView.swift`:
  ```swift
  import SwiftUI
  import PhotosCore

  @MainActor
  @Observable
  final class LoginFormModel {
      private let auth: AuthStateMachine
      var host: String = "https://"
      var username: String = ""
      var password: String = ""
      var otpCode: String = ""
      var showOtp: Bool = false
      var isBusy: Bool = false
      var errorText: String?

      init(auth: AuthStateMachine) { self.auth = auth }

      func submit() async {
          isBusy = true
          defer { isBusy = false }
          let otp = showOtp && !otpCode.isEmpty ? otpCode : nil
          await auth.attemptLogin(host: host, username: username, password: password, otpCode: otp, pinnedCertDer: nil)
          sync(with: auth.phase)
      }

      /// Reflect the auth phase into the form UI (OTP visibility + error text).
      func sync(with phase: AuthPhase) {
          switch phase {
          case .needsOtp:
              showOtp = true
              errorText = "Enter your two-factor code to continue."
          case .invalid(let message):
              errorText = message
          case .valid:
              errorText = nil
          case .expired:
              errorText = "Your session expired. Sign in again."
          default:
              break
          }
      }
  }

  struct LoginView: View {
      @State private var model: LoginFormModel
      private let auth: AuthStateMachine

      init(auth: AuthStateMachine) {
          self.auth = auth
          _model = State(initialValue: LoginFormModel(auth: auth))
      }

      var body: some View {
          VStack(alignment: .leading, spacing: 12) {
              Text("Connect to Synology Photos").font(.title2).bold()
              TextField("Server, e.g. https://192.168.1.10:5001", text: $model.host)
                  .textContentType(.URL).accessibilityIdentifier("login.host")
              TextField("Username", text: $model.username)
                  .textContentType(.username).accessibilityIdentifier("login.username")
              SecureField("Password", text: $model.password)
                  .textContentType(.password).accessibilityIdentifier("login.password")
              if model.showOtp {
                  TextField("Two-factor code", text: $model.otpCode)
                      .accessibilityIdentifier("login.otp")
              }
              if let err = model.errorText {
                  Text(err).foregroundStyle(.red).font(.callout).accessibilityIdentifier("login.error")
              }
              Button(model.showOtp ? "Verify" : "Sign In") { Task { await model.submit() } }
                  .disabled(model.isBusy).accessibilityIdentifier("login.submit")
          }
          .padding(24)
          .frame(width: 380)
          .onChange(of: auth.phase) { _, newPhase in model.sync(with: newPhase) }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/LoginViewModelTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'LoginViewModelTests' passed`, 4 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add login form with conditional OTP field and phase-driven errors"
  ```

---

### Task 44: `PathMonitor` reachability + `HostSelector` (LAN-first, Tailscale fallback with cert pinning)

**Files**
- Create: `app/SynologyPhotos/Reachability/PathMonitor.swift`
- Create: `app/SynologyPhotosTests/PathMonitorTests.swift`

**Interfaces**
- Consumes: Network framework, `Connection`.
- Produces: `enum Reachability { unknown, offline, online }`; `enum PreferredHost { lan(String), tailscale(String) }`; `@MainActor @Observable final class PathMonitor { var reachability; func start(); func stop() }`; `struct HostSelector` with `static func choose(lanHost:tailscaleHost:canReachLan:) -> PreferredHost` and `static func connection(for:pinnedCertDer:) -> Connection`. LAN uses system trust (`pinnedCertDer` nil even if one is supplied); the Tailscale name pins the DER with `verifyTls == true` (contract 2.6).

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/PathMonitorTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  struct PathMonitorTests {
      @Test func prefersLanWhenReachable() {
          let choice = HostSelector.choose(lanHost: "https://192.168.1.10:5001",
                                           tailscaleHost: "https://nas.tailnet.ts.net:5001", canReachLan: true)
          #expect(choice == .lan("https://192.168.1.10:5001"))
      }

      @Test func fallsBackToTailscaleWhenLanUnreachable() {
          let choice = HostSelector.choose(lanHost: "https://192.168.1.10:5001",
                                           tailscaleHost: "https://nas.tailnet.ts.net:5001", canReachLan: false)
          #expect(choice == .tailscale("https://nas.tailnet.ts.net:5001"))
      }

      @Test func staysOnLanWhenNoTailscaleConfigured() {
          let choice = HostSelector.choose(lanHost: "https://192.168.1.10:5001", tailscaleHost: nil, canReachLan: false)
          #expect(choice == .lan("https://192.168.1.10:5001"))
      }

      @Test func lanConnectionUsesSystemTrust() {
          let conn = HostSelector.connection(for: .lan("https://192.168.1.10:5001"), pinnedCertDer: [1, 2, 3])
          #expect(conn.verifyTls == true)
          #expect(conn.pinnedCertDer == nil)
      }

      @Test func tailscaleConnectionPinsCert() {
          let conn = HostSelector.connection(for: .tailscale("https://nas.ts.net:5001"), pinnedCertDer: [9, 9])
          #expect(conn.verifyTls == true)
          #expect(conn.pinnedCertDer == [9, 9])
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/PathMonitorTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'HostSelector' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Reachability/PathMonitor.swift`:
  ```swift
  import Foundation
  import Network
  import PhotosCore

  enum Reachability: Equatable { case unknown, offline, online }
  enum PreferredHost: Equatable { case lan(String), tailscale(String) }

  @MainActor
  @Observable
  final class PathMonitor {
      var reachability: Reachability = .unknown
      private let monitor = NWPathMonitor()
      private let queue = DispatchQueue(label: "com.synologynativephotos.pathmonitor")

      func start() {
          monitor.pathUpdateHandler = { [weak self] path in
              let r: Reachability = path.status == .satisfied ? .online : .offline
              Task { @MainActor in self?.reachability = r }
          }
          monitor.start(queue: queue)
      }

      func stop() { monitor.cancel() }
  }

  /// Chooses LAN-first, Tailscale fallback, and builds the matching Connection.
  /// TLS is never globally disabled (contract 2.6): the Tailscale name whose cert
  /// CN will not match is trusted only by pinning the captured DER on that one host.
  struct HostSelector {
      static func choose(lanHost: String, tailscaleHost: String?, canReachLan: Bool) -> PreferredHost {
          if canReachLan { return .lan(lanHost) }
          if let ts = tailscaleHost { return .tailscale(ts) }
          return .lan(lanHost)
      }

      static func connection(for host: PreferredHost, pinnedCertDer: [UInt8]?) -> Connection {
          switch host {
          case .lan(let h):
              return Connection(host: h, verifyTls: true, pinnedCertDer: nil)
          case .tailscale(let h):
              return Connection(host: h, verifyTls: true, pinnedCertDer: pinnedCertDer)
          }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/PathMonitorTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'PathMonitorTests' passed`, 5 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add reachability monitor with LAN-first Tailscale fallback and cert pinning"
  ```

---

### Task 45: `ImageDownsample` (ImageIO off-main)

**Files**
- Create: `app/SynologyPhotos/Thumbnails/ImageDownsample.swift`
- Create: `app/SynologyPhotosTests/ImageDownsampleTests.swift`

**Interfaces**
- Consumes: ImageIO, CoreGraphics.
- Produces: `enum ImageDownsample` with `static func downsample(data: Data, maxPixel: Int) -> CGImage?` and `static func downsample(fileURL: URL, maxPixel: Int) -> CGImage?`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/ImageDownsampleTests.swift`:
  ```swift
  import Testing
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers
  @testable import SynologyPhotos

  struct ImageDownsampleTests {
      private func makePNG(width: Int, height: Int) -> Data {
          let cs = CGColorSpaceCreateDeviceRGB()
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
          ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
          ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
          let cg = ctx.makeImage()!
          let out = NSMutableData()
          let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
          CGImageDestinationAddImage(dest, cg, nil)
          CGImageDestinationFinalize(dest)
          return out as Data
      }

      @Test func downsamplesToRequestedMaxPixel() throws {
          let data = makePNG(width: 800, height: 600)
          let img = try #require(ImageDownsample.downsample(data: data, maxPixel: 240))
          #expect(max(img.width, img.height) <= 240)
          #expect(img.width > 0 && img.height > 0)
      }

      @Test func downsampleFromFileURL() throws {
          let data = makePNG(width: 1000, height: 400)
          let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID()).png")
          try data.write(to: url)
          defer { try? FileManager.default.removeItem(at: url) }
          let img = try #require(ImageDownsample.downsample(fileURL: url, maxPixel: 320))
          #expect(max(img.width, img.height) <= 320)
      }

      @Test func garbageDataReturnsNil() {
          #expect(ImageDownsample.downsample(data: Data([0, 1, 2, 3]), maxPixel: 100) == nil)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/ImageDownsampleTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'ImageDownsample' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Thumbnails/ImageDownsample.swift`:
  ```swift
  import Foundation
  import ImageIO
  import CoreGraphics

  /// Off-main image decode. Callers must invoke from a background context;
  /// ImageIO thumbnail decode does the heavy work without a full source decode.
  enum ImageDownsample {
      private static func options(maxPixel: Int) -> CFDictionary {
          [
              kCGImageSourceCreateThumbnailFromImageAlways: true,
              kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceShouldCacheImmediately: true,
              kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          ] as CFDictionary
      }

      static func downsample(data: Data, maxPixel: Int) -> CGImage? {
          let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
          guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
          return CGImageSourceCreateThumbnailAtIndex(src, 0, options(maxPixel: maxPixel))
      }

      static func downsample(fileURL: URL, maxPixel: Int) -> CGImage? {
          let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
          guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, srcOpts) else { return nil }
          return CGImageSourceCreateThumbnailAtIndex(src, 0, options(maxPixel: maxPixel))
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/ImageDownsampleTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'ImageDownsampleTests' passed`, 3 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add ImageIO downsample helper for off-main thumbnail decode"
  ```

---

### Task 46: `ThumbnailCache` two-tier (byte-cost NSCache + on-disk composite key)

**Files**
- Create: `app/SynologyPhotos/Thumbnails/ThumbnailCache.swift`
- Create: `app/SynologyPhotosTests/ThumbnailCacheTests.swift`

**Interfaces**
- Consumes: `PhotosCoreClient` (Task 40), `ImageDownsample` (Task 45), `ThumbnailData`, `ThumbnailSize`, `Space`, `Asset`.
- Produces: `struct ThumbKey: Hashable`; `actor ThumbnailCache` with `init(client:memoryByteLimit:)`, `func image(space:asset:size:) async -> CGImage?`, `func invalidate(assetId:)`; `static func maxPixel(for: ThumbnailSize) -> Int` (sm=240, m=320, xl=1280).

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/ThumbnailCacheTests.swift`:
  ```swift
  import Testing
  import CoreGraphics
  import ImageIO
  import UniformTypeIdentifiers
  import PhotosCore
  @testable import SynologyPhotos

  struct ThumbnailCacheTests {
      private func writePNG(width: Int, height: Int) -> String {
          let cs = CGColorSpaceCreateDeviceRGB()
          let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
          ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
          ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
          let cg = ctx.makeImage()!
          let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID()).png")
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
          CGImageDestinationAddImage(dest, cg, nil)
          CGImageDestinationFinalize(dest)
          return url.path
      }

      private func asset(id: Int64) -> Asset {
          Asset(id: id, cacheKey: "v1", filename: "IMG_\(id).jpg", mediaKind: .photo,
                takenAt: 1_700_000_000, addedAt: nil, width: 800, height: 600,
                fileSize: nil, space: .personal, serverVersion: 1)
      }

      @Test func maxPixelMapping() {
          #expect(ThumbnailCache.maxPixel(for: .sm) == 240)
          #expect(ThumbnailCache.maxPixel(for: .m) == 320)
          #expect(ThumbnailCache.maxPixel(for: .xl) == 1280)
      }

      @Test func fetchesDecodesAndReturnsImage() async {
          let fake = FakePhotosCore()
          let path = writePNG(width: 800, height: 600)
          defer { try? FileManager.default.removeItem(atPath: path) }
          fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: []))
          let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
          let img = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
          #expect(img != nil)
          #expect(max(img?.width ?? 9999, img?.height ?? 9999) <= 240)
      }

      @Test func secondFetchServedFromMemory() async {
          let fake = FakePhotosCore()
          let path = writePNG(width: 800, height: 600)
          defer { try? FileManager.default.removeItem(atPath: path) }
          fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: []))
          let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
          _ = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
          try? FileManager.default.removeItem(atPath: path)
          let img2 = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
          #expect(img2 != nil)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/ThumbnailCacheTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'ThumbnailCache' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Thumbnails/ThumbnailCache.swift`:
  ```swift
  import Foundation
  import CoreGraphics
  import PhotosCore

  struct ThumbKey: Hashable {
      let assetId: Int64
      let size: ThumbnailSize
      let cacheKey: String
  }

  /// Two-tier thumbnail cache.
  /// Tier 1: in-memory NSCache limited by total byte cost.
  /// Tier 2: on disk, owned by the core (ThumbnailData.cachedPath), keyed by the
  ///         composite (asset_id, size, cache_key). A changed cache_key yields a
  ///         different core path, so a stale entry is never served.
  actor ThumbnailCache {
      private let client: PhotosCoreClient
      private let memory = NSCache<NSString, CacheBox>()

      final class CacheBox { let image: CGImage; init(_ i: CGImage) { image = i } }

      init(client: PhotosCoreClient, memoryByteLimit: Int = 128 * 1024 * 1024) {
          self.client = client
          memory.totalCostLimit = memoryByteLimit
      }

      static func maxPixel(for size: ThumbnailSize) -> Int {
          switch size {
          case .sm: return 240
          case .m: return 320
          case .xl: return 1280
          }
      }

      private func key(_ k: ThumbKey) -> NSString { "\(k.assetId)|\(k.size)|\(k.cacheKey)" as NSString }
      private static func byteCost(_ image: CGImage) -> Int { image.bytesPerRow * image.height }

      func image(space: Space, asset: Asset, size: ThumbnailSize) async -> CGImage? {
          let tk = ThumbKey(assetId: asset.id, size: size, cacheKey: asset.cacheKey)
          if let hit = memory.object(forKey: key(tk)) { return hit.image }
          let data: ThumbnailData
          do {
              data = try await client.thumbnail(space: space, assetId: asset.id, cacheKey: asset.cacheKey, size: size)
          } catch { return nil }
          let maxPixel = Self.maxPixel(for: size)
          let path = data.cachedPath
          let decoded: CGImage? = await Task.detached(priority: .utility) {
              ImageDownsample.downsample(fileURL: URL(fileURLWithPath: path), maxPixel: maxPixel)
          }.value
          if let img = decoded {
              memory.setObject(CacheBox(img), forKey: key(tk), cost: Self.byteCost(img))
          }
          return decoded
      }

      /// Drop all in-memory entries (e.g. after a cache_key change or sign out).
      func invalidate(assetId: Int64) {
          memory.removeAllObjects()
          _ = assetId
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/ThumbnailCacheTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'ThumbnailCacheTests' passed`, 3 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add two-tier thumbnail cache with byte-cost memory tier over core disk cache"
  ```

---

### Task 47: `WindowedDataSource` bridging `fetchAssets` (never the whole library)

**Files**
- Create: `app/SynologyPhotos/Grid/WindowedDataSource.swift`
- Create: `app/SynologyPhotosTests/WindowedDataSourceTests.swift`

**Interfaces**
- Consumes: `PhotosCoreClient` (Task 40), `Asset`, `Space`, `CrawlProgress`.
- Produces: `struct AssetItemID: Hashable { let space: Space; let serverId: Int64 }`; `@MainActor @Observable final class WindowedDataSource` with `init(client:space:pageSize:)`, `var totalCount`, `var isReady`, `let pageSize`, `private(set) var space`, `func refreshCount() async`, `func loadWindow(offset:limit:) async -> [Asset]` (`@discardableResult`), `func item(at:) -> Asset?`, `func setSpace(_:) async`. Gates `isReady` on `crawlProgress().complete`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/WindowedDataSourceTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct WindowedDataSourceTests {
      private func asset(_ id: Int64) -> Asset {
          Asset(id: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
                takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
                fileSize: nil, space: .personal, serverVersion: id)
      }

      @Test func loadsOnlyRequestedWindow() async {
          let fake = FakePhotosCore()
          fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
          fake.progressByspace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
          let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
          await ds.refreshCount()
          #expect(ds.totalCount == 500)
          #expect(ds.isReady == true)
          let window = await ds.loadWindow(offset: 100, limit: 50)
          #expect(window.count == 50)
          #expect(window.first?.id == 100)
          #expect(ds.item(at: 120)?.id == 120)
          #expect(ds.item(at: 400) == nil)
      }

      @Test func notReadyWhenCrawlIncomplete() async {
          let fake = FakePhotosCore()
          fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
          fake.progressByspace[.personal] = CrawlProgress(space: .personal, done: 3, total: 10, complete: false)
          let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
          await ds.refreshCount()
          #expect(ds.isReady == false)
      }

      @Test func setSpaceRequeries() async {
          let fake = FakePhotosCore()
          fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
          fake.assets[.shared] = (0..<3).map { asset(Int64($0)) }
          fake.progressByspace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
          fake.progressByspace[.shared] = CrawlProgress(space: .shared, done: 3, total: 3, complete: true)
          let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
          await ds.refreshCount()
          #expect(ds.totalCount == 10)
          await ds.setSpace(.shared)
          #expect(ds.totalCount == 3)
          #expect(ds.item(at: 9) == nil)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/WindowedDataSourceTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'WindowedDataSource' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Grid/WindowedDataSource.swift`:
  ```swift
  import Foundation
  import PhotosCore

  struct AssetItemID: Hashable {
      let space: Space
      let serverId: Int64
  }

  /// Bridges the NSCollectionView grid to the core's windowed reads. Holds only a
  /// bounded set of loaded rows keyed by absolute index; never calls a fetch-all API.
  /// Gates readiness on crawl completion so the grid does not show a partial crawl
  /// as if it were the full library.
  @MainActor
  @Observable
  final class WindowedDataSource {
      private let client: PhotosCoreClient
      private(set) var space: Space
      let pageSize: Int
      private(set) var totalCount: Int = 0
      private(set) var isReady: Bool = false
      private var resident: [Int: Asset] = [:]

      init(client: PhotosCoreClient, space: Space, pageSize: Int = 200) {
          self.client = client
          self.space = space
          self.pageSize = pageSize
      }

      func refreshCount() async {
          do {
              let count = try await client.assetCount(space: space)
              totalCount = Int(count)
              let progress = try await client.crawlProgress(space: space)
              isReady = progress.complete
          } catch {
              totalCount = 0
              isReady = false
          }
      }

      @discardableResult
      func loadWindow(offset: Int, limit: Int) async -> [Asset] {
          guard offset >= 0, limit > 0 else { return [] }
          do {
              let rows = try await client.fetchAssets(space: space, offset: UInt32(offset), limit: UInt32(limit))
              for (i, asset) in rows.enumerated() { resident[offset + i] = asset }
              return rows
          } catch {
              return []
          }
      }

      func item(at index: Int) -> Asset? { resident[index] }

      func setSpace(_ newSpace: Space) async {
          space = newSpace
          resident.removeAll()
          await refreshCount()
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/WindowedDataSourceTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'WindowedDataSourceTests' passed`, 3 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add windowed data source that reads bounded slices and gates on crawl completion"
  ```

---

### Task 48: `PhotoCellView` + `PhotoGridController` (NSCollectionView + diffable)

**Files**
- Create: `app/SynologyPhotos/Grid/PhotoCellView.swift`
- Create: `app/SynologyPhotos/Grid/PhotoGridController.swift`
- Create: `app/SynologyPhotosTests/PhotoGridControllerTests.swift`

**Interfaces**
- Consumes: `WindowedDataSource` (Task 47), `ThumbnailCache` (Task 46), `AssetItemID` (Task 47), `Asset`, `Space`.
- Produces: `final class PhotoCellView: NSCollectionViewItem` with `configure(asset:space:cache:)`, `var representedAssetId: Int64`, static `reuseIdentifier`; `@MainActor final class PhotoGridController: NSViewController, NSCollectionViewPrefetching` with `init(dataSource:cache:)`, `let collectionView`, `func applySnapshot() async`, `func snapshotItemCount() -> Int`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/PhotoGridControllerTests.swift`:
  ```swift
  import Testing
  import AppKit
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct PhotoGridControllerTests {
      private func asset(_ id: Int64) -> Asset {
          Asset(id: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
                takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
                fileSize: nil, space: .personal, serverVersion: id)
      }

      @Test func snapshotReflectsLoadedWindow() async {
          let fake = FakePhotosCore()
          fake.assets[.personal] = (0..<120).map { asset(Int64($0)) }
          fake.progressByspace[.personal] = CrawlProgress(space: .personal, done: 120, total: 120, complete: true)
          let client = PhotosCoreClient(core: fake)
          let ds = WindowedDataSource(client: client, space: .personal, pageSize: 60)
          let cache = ThumbnailCache(client: client)
          let controller = PhotoGridController(dataSource: ds, cache: cache)
          _ = controller.view
          await ds.refreshCount()
          await ds.loadWindow(offset: 0, limit: 60)
          await controller.applySnapshot()
          #expect(controller.snapshotItemCount() == 60)
      }

      @Test func cellConfigureDoesNotCrashWithoutImage() {
          let cell = PhotoCellView()
          _ = cell.view
          let cache = ThumbnailCache(client: PhotosCoreClient(core: FakePhotosCore()))
          cell.configure(asset: asset(1), space: .personal, cache: cache)
          #expect(cell.representedAssetId == 1)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/PhotoGridControllerTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'PhotoGridController' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Grid/PhotoCellView.swift`:
  ```swift
  import AppKit
  import PhotosCore

  /// One grid cell. Loads its thumbnail asynchronously; guards against reuse by
  /// checking the represented asset id before applying a late-arriving image.
  final class PhotoCellView: NSCollectionViewItem {
      static let reuseIdentifier = NSUserInterfaceItemIdentifier("PhotoCellView")

      private let thumbView = NSImageView()
      private(set) var representedAssetId: Int64 = -1
      private var loadTask: Task<Void, Never>?

      override func loadView() {
          let container = NSView()
          thumbView.imageScaling = .scaleProportionallyUpOrDown
          thumbView.translatesAutoresizingMaskIntoConstraints = false
          thumbView.wantsLayer = true
          thumbView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
          container.addSubview(thumbView)
          NSLayoutConstraint.activate([
              thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
              thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
              thumbView.topAnchor.constraint(equalTo: container.topAnchor),
              thumbView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
          ])
          self.view = container
      }

      override func prepareForReuse() {
          super.prepareForReuse()
          loadTask?.cancel()
          thumbView.image = nil
          representedAssetId = -1
      }

      @MainActor
      func configure(asset: Asset, space: Space, cache: ThumbnailCache) {
          representedAssetId = asset.id
          view.setAccessibilityIdentifier("grid.cell.\(asset.id)")
          let targetId = asset.id
          loadTask?.cancel()
          loadTask = Task { [weak self] in
              let cg = await cache.image(space: space, asset: asset, size: .sm)
              guard let self, self.representedAssetId == targetId, let cg else { return }
              self.thumbView.image = NSImage(cgImage: cg, size: .zero)
          }
      }
  }
  ```
  And `app/SynologyPhotos/Grid/PhotoGridController.swift`:
  ```swift
  import AppKit
  import PhotosCore

  /// Hosts an NSCollectionView backed by a diffable data source keyed on
  /// AssetItemID. Reads only windowed slices via WindowedDataSource; prefetch
  /// triggers the next window load.
  @MainActor
  final class PhotoGridController: NSViewController, NSCollectionViewPrefetching {
      private let dataSource: WindowedDataSource
      private let cache: ThumbnailCache
      let collectionView = NSCollectionView()
      private var diffable: NSCollectionViewDiffableDataSource<Int, AssetItemID>!

      init(dataSource: WindowedDataSource, cache: ThumbnailCache) {
          self.dataSource = dataSource
          self.cache = cache
          super.init(nibName: nil, bundle: nil)
      }
      required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

      override func loadView() {
          let scroll = NSScrollView()
          let layout = NSCollectionViewFlowLayout()
          layout.itemSize = NSSize(width: 160, height: 160)
          layout.minimumInteritemSpacing = 4
          layout.minimumLineSpacing = 4
          collectionView.collectionViewLayout = layout
          collectionView.isSelectable = true
          collectionView.prefetchDataSource = self
          collectionView.register(PhotoCellView.self, forItemWithIdentifier: PhotoCellView.reuseIdentifier)
          collectionView.setAccessibilityIdentifier("grid.collection")
          scroll.documentView = collectionView
          scroll.hasVerticalScroller = true
          self.view = scroll
      }

      override func viewDidLoad() {
          super.viewDidLoad()
          diffable = NSCollectionViewDiffableDataSource<Int, AssetItemID>(collectionView: collectionView) { [weak self] cv, indexPath, itemID in
              let item = cv.makeItem(withIdentifier: PhotoCellView.reuseIdentifier, for: indexPath)
              guard let cell = item as? PhotoCellView, let self else { return item }
              if let asset = self.dataSource.item(at: indexPath.item) {
                  cell.configure(asset: asset, space: itemID.space, cache: self.cache)
              }
              return cell
          }
      }

      /// Build a snapshot from the currently resident window rows.
      func applySnapshot() async {
          var snap = NSDiffableDataSourceSnapshot<Int, AssetItemID>()
          snap.appendSections([0])
          var ids: [AssetItemID] = []
          for index in 0..<dataSource.totalCount {
              if let asset = dataSource.item(at: index) {
                  ids.append(AssetItemID(space: asset.space, serverId: asset.id))
              }
          }
          snap.appendItems(ids, toSection: 0)
          diffable.apply(snap, animatingDifferences: false)
      }

      func snapshotItemCount() -> Int { diffable.snapshot().numberOfItems }

      func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
          guard let minIndex = indexPaths.map(\.item).min() else { return }
          let offset = (minIndex / dataSource.pageSize) * dataSource.pageSize
          Task {
              await dataSource.loadWindow(offset: offset, limit: dataSource.pageSize)
              await applySnapshot()
          }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/PhotoGridControllerTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'PhotoGridControllerTests' passed`, 2 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add NSCollectionView grid controller with diffable data source and prefetch"
  ```

---

### Task 49: `PhotoGridView` NSViewControllerRepresentable + `SpaceToggle` re-query

**Files**
- Create: `app/SynologyPhotos/Grid/PhotoGridView.swift`
- Create: `app/SynologyPhotos/Session/SpaceToggle.swift`
- Create: `app/SynologyPhotosTests/SpaceToggleTests.swift`

**Interfaces**
- Consumes: `PhotoGridController` (Task 48), `WindowedDataSource` (Task 47), `Space`.
- Produces: `struct PhotoGridView: NSViewControllerRepresentable { let controller: PhotoGridController }`; `@MainActor @Observable final class SpaceSelection { var current: Space; func toggle(to:on:) async }`; `struct SpaceToggleView: View { init(selection:dataSource:onChange:) }`. A11y id `space.toggle`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/SpaceToggleTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct SpaceToggleTests {
      private func asset(_ id: Int64, _ space: Space) -> Asset {
          Asset(id: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
                takenAt: 1_700_000_000, addedAt: nil, width: 1, height: 1,
                fileSize: nil, space: space, serverVersion: id)
      }

      @Test func toggleSwitchesSpaceAndRequeries() async {
          let fake = FakePhotosCore()
          fake.assets[.personal] = (0..<10).map { asset(Int64($0), .personal) }
          fake.assets[.shared] = (0..<4).map { asset(Int64($0), .shared) }
          fake.progressByspace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
          fake.progressByspace[.shared] = CrawlProgress(space: .shared, done: 4, total: 4, complete: true)
          let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
          await ds.refreshCount()
          let sel = SpaceSelection(current: .personal)
          await sel.toggle(to: .shared, on: ds)
          #expect(sel.current == .shared)
          #expect(ds.totalCount == 4)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/SpaceToggleTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'SpaceSelection' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Session/SpaceToggle.swift`:
  ```swift
  import SwiftUI
  import PhotosCore

  /// Personal/Shared selection. Switching re-queries the data source by space
  /// (Personal => SYNO.Foto.*, Shared => SYNO.FotoTeam.* on the core side).
  @MainActor
  @Observable
  final class SpaceSelection {
      var current: Space
      init(current: Space) { self.current = current }

      func toggle(to space: Space, on dataSource: WindowedDataSource) async {
          guard space != current else { return }
          current = space
          await dataSource.setSpace(space)
      }
  }

  struct SpaceToggleView: View {
      @State private var selection: SpaceSelection
      private let dataSource: WindowedDataSource
      private let onChange: () async -> Void

      init(selection: SpaceSelection, dataSource: WindowedDataSource, onChange: @escaping () async -> Void) {
          _selection = State(initialValue: selection)
          self.dataSource = dataSource
          self.onChange = onChange
      }

      var body: some View {
          Picker("Space", selection: Binding(
              get: { selection.current },
              set: { newValue in
                  Task {
                      await selection.toggle(to: newValue, on: dataSource)
                      await onChange()
                  }
              }
          )) {
              Text("Personal").tag(Space.personal)
              Text("Shared").tag(Space.shared)
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("space.toggle")
      }
  }
  ```
  And `app/SynologyPhotos/Grid/PhotoGridView.swift`:
  ```swift
  import SwiftUI
  import AppKit

  /// SwiftUI host for the AppKit grid controller.
  struct PhotoGridView: NSViewControllerRepresentable {
      let controller: PhotoGridController
      func makeNSViewController(context: Context) -> PhotoGridController { controller }
      func updateNSViewController(_ nsViewController: PhotoGridController, context: Context) {}
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/SpaceToggleTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'SpaceToggleTests' passed`, 1 test.
- [ ] Commit:
  ```
  git add app && git commit -m "Add SwiftUI grid host and Personal/Shared space toggle re-query"
  ```

---

### Task 50: Crawl progress ("importing N of M") gated on barrier

**Files**
- Create: `app/SynologyPhotos/Session/CrawlProgressModel.swift`
- Create: `app/SynologyPhotosTests/CrawlProgressModelTests.swift`

**Interfaces**
- Consumes: `PhotosCoreClient` (Task 40), `FfiCrawlObserver` (contract 2.4), `CrawlProgress`, `Space`.
- Produces: `@MainActor @Observable final class CrawlProgressModel` with `var done/total/isComplete`, `var statusText: String`, `func apply(_:)`, `func startCrawl(space:) async`, and an internal `final class Observer: FfiCrawlObserver` forwarding `onProgress` onto the main actor.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/CrawlProgressModelTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct CrawlProgressModelTests {
      @Test func emitsImportingTextThenCompletes() async {
          let fake = FakePhotosCore()
          fake.crawlProgressToEmit = [
              CrawlProgress(space: .personal, done: 100, total: 1000, complete: false),
              CrawlProgress(space: .personal, done: 500, total: 1000, complete: false),
          ]
          fake.crawlFinal[.personal] = CrawlProgress(space: .personal, done: 1000, total: 1000, complete: true)
          let model = CrawlProgressModel(client: PhotosCoreClient(core: fake))
          await model.startCrawl(space: .personal)
          #expect(model.isComplete == true)
          #expect(model.done == 1000)
          #expect(model.total == 1000)
          #expect(model.statusText.contains("1000"))
      }

      @Test func importingTextFormat() {
          let model = CrawlProgressModel(client: PhotosCoreClient(core: FakePhotosCore()))
          model.apply(CrawlProgress(space: .personal, done: 42, total: 900, complete: false))
          #expect(model.statusText == "Importing 42 of 900")
          #expect(model.isComplete == false)
      }

      @Test func completeShowsReadyText() {
          let model = CrawlProgressModel(client: PhotosCoreClient(core: FakePhotosCore()))
          model.apply(CrawlProgress(space: .personal, done: 900, total: 900, complete: true))
          #expect(model.isComplete == true)
          #expect(model.statusText.localizedCaseInsensitiveContains("ready") ||
                  model.statusText.localizedCaseInsensitiveContains("900"))
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/CrawlProgressModelTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'CrawlProgressModel' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Session/CrawlProgressModel.swift`:
  ```swift
  import Foundation
  import PhotosCore

  /// Observes the initial crawl and surfaces "Importing N of M". Only reports ready
  /// when the core flips the initial_crawl_complete barrier (complete=true); the grid
  /// must not treat a partial crawl as the full library.
  @MainActor
  @Observable
  final class CrawlProgressModel {
      private let client: PhotosCoreClient
      var done: UInt64 = 0
      var total: UInt64 = 0
      var isComplete: Bool = false

      init(client: PhotosCoreClient) { self.client = client }

      var statusText: String {
          if isComplete { return "Ready. \(done) items." }
          if total == 0 { return "Importing..." }
          return "Importing \(done) of \(total)"
      }

      func apply(_ p: CrawlProgress) {
          done = p.done
          total = p.total
          isComplete = p.complete
      }

      /// Callback bridge from Rust; forwards each progress tick onto the main actor.
      final class Observer: FfiCrawlObserver, @unchecked Sendable {
          private let sink: @Sendable (CrawlProgress) -> Void
          init(sink: @escaping @Sendable (CrawlProgress) -> Void) { self.sink = sink }
          func onProgress(progress: CrawlProgress) { sink(progress) }
      }

      func startCrawl(space: Space) async {
          let observer = Observer { [weak self] p in
              Task { @MainActor in self?.apply(p) }
          }
          do {
              let final = try await client.crawlSpace(space: space, observer: observer)
              apply(final)
          } catch {
              isComplete = false
          }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/CrawlProgressModelTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'CrawlProgressModelTests' passed`, 3 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add importing-progress model gated on the initial crawl barrier"
  ```

---

### Task 51: `DetailQuickLookView` (download-to-temp, bounded temp cache)

**Files**
- Create: `app/SynologyPhotos/Detail/DetailQuickLookView.swift`
- Create: `app/SynologyPhotosTests/TempCacheTests.swift`

**Interfaces**
- Consumes: `PhotosCoreClient` (Task 40), `Asset`, `Space`, Quartz/QuickLookUI.
- Produces: `actor TempFileCache` with `init(limit:)`, `func store(path:) -> URL` (`@discardableResult`), `func evictIfNeeded()`, `func clearAll()`; `struct DetailQuickLookView: NSViewRepresentable` init `(asset:space:client:cache:)`.

**Format decision notes** (recorded in the file header, load-bearing for Phase 1 scope): QuickLook (`QLPreviewView`) natively renders HEIC, most camera RAW, and common video containers via the same download-to-temp path; verify against real NAS originals in Task 53 (RealNAS). Live Photos re-pairing (rejoining the still + paired MOV into one `PHLivePhoto`) is DEFERRED past Phase 1; the read-only MVP previews the still and any video as separate originals.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/TempCacheTests.swift`:
  ```swift
  import Testing
  import Foundation
  @testable import SynologyPhotos

  struct TempCacheTests {
      private func makeTempFile() -> String {
          let url = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID()).bin")
          FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2]))
          return url.path
      }

      @Test func storeReturnsExistingPath() async {
          let cache = TempFileCache(limit: 4)
          let path = makeTempFile()
          defer { try? FileManager.default.removeItem(atPath: path) }
          let url = await cache.store(path: path)
          #expect(url.path == path)
      }

      @Test func evictsOldestBeyondLimit() async {
          let cache = TempFileCache(limit: 2)
          var paths: [String] = []
          for _ in 0..<3 { let p = makeTempFile(); paths.append(p); _ = await cache.store(path: p) }
          #expect(FileManager.default.fileExists(atPath: paths[0]) == false)
          #expect(FileManager.default.fileExists(atPath: paths[2]) == true)
          for p in paths { try? FileManager.default.removeItem(atPath: p) }
      }

      @Test func clearAllRemovesResident() async {
          let cache = TempFileCache(limit: 4)
          let p = makeTempFile()
          _ = await cache.store(path: p)
          await cache.clearAll()
          #expect(FileManager.default.fileExists(atPath: p) == false)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/TempCacheTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'TempFileCache' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Detail/DetailQuickLookView.swift`:
  ```swift
  import SwiftUI
  import AppKit
  import Quartz
  import PhotosCore

  // Format support (read-only Phase 1):
  //  - QLPreviewView renders HEIC, most camera RAW, and common video containers
  //    from the downloaded original. Verify against real NAS files (Task 53, RealNAS).
  //  - Live Photos re-pairing (still + paired MOV into one PHLivePhoto) is DEFERRED
  //    past Phase 1. The MVP previews the still and any video as separate originals.

  /// Bounds downloaded originals in the temp dir by count; deletes the oldest first.
  actor TempFileCache {
      private let limit: Int
      private var order: [String] = []

      init(limit: Int = 24) { self.limit = max(1, limit) }

      @discardableResult
      func store(path: String) -> URL {
          if !order.contains(path) { order.append(path) }
          evictIfNeeded()
          return URL(fileURLWithPath: path)
      }

      func evictIfNeeded() {
          while order.count > limit {
              let victim = order.removeFirst()
              try? FileManager.default.removeItem(atPath: victim)
          }
      }

      func clearAll() {
          for p in order { try? FileManager.default.removeItem(atPath: p) }
          order.removeAll()
      }
  }

  struct DetailQuickLookView: NSViewRepresentable {
      let asset: Asset
      let space: Space
      let client: PhotosCoreClient
      let cache: TempFileCache

      func makeNSView(context: Context) -> QLPreviewView {
          let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
          preview.setAccessibilityIdentifier("detail.quicklook")
          return preview
      }

      func updateNSView(_ nsView: QLPreviewView, context: Context) {
          let a = asset, s = space, c = client, tc = cache
          Task {
              do {
                  let path = try await c.downloadOriginal(space: s, assetId: a.id, cacheKey: a.cacheKey)
                  let url = await tc.store(path: path)
                  await MainActor.run { nsView.previewItem = url as NSURL }
              } catch {
                  // Read-only: on failure, leave the preview empty; no mutation of the NAS.
              }
          }
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/TempCacheTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'TempCacheTests' passed`, 3 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Add QuickLook detail with download-to-temp and count-bounded temp cache"
  ```

---

### Task 52: `SignOutController` clean teardown (SID clear, per-account cache wipe, return to login)

**Files**
- Create: `app/SynologyPhotos/Session/SignOutController.swift`
- Create: `app/SynologyPhotosTests/SignOutControllerTests.swift`

**Interfaces**
- Consumes: `PhotosCoreClient` (Task 40), `KeychainSID` (Task 41), `AuthStateMachine` (Task 42), `ThumbnailCache` (Task 46), `TempFileCache` (Task 51).
- Produces: `@MainActor final class SignOutController` with `init(client:auth:keychainHost:keychainUsername:accountCacheDir:thumbnailCache:tempCache:)` and `func signOut() async`. On completion: core `signOut` called, Keychain entry cleared, account cache dir contents removed, temp cache cleared, `auth.reset()` (phase back to `.loggedOut`). One account at a time (locked decision).

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/SignOutControllerTests.swift`:
  ```swift
  import Testing
  import Foundation
  import PhotosCore
  @testable import SynologyPhotos

  @MainActor
  struct SignOutControllerTests {
      @Test func signOutClearsSessionKeychainCacheAndPhase() async throws {
          let fake = FakePhotosCore()
          let client = PhotosCoreClient(core: fake)
          let auth = AuthStateMachine(client: client)
          auth.phase = .valid(Session(sid: "S", synoToken: nil, username: "sotest", deviceDid: nil))
          let host = "https://signout-test.local:5001"
          try KeychainSID.save(Session(sid: "S", synoToken: nil, username: "sotest", deviceDid: nil), host: host)
          let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("acct-cache-\(UUID())")
          try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
          let dummy = cacheDir.appendingPathComponent("thumb.jpg")
          FileManager.default.createFile(atPath: dummy.path, contents: Data([1]))
          let controller = SignOutController(
              client: client, auth: auth,
              keychainHost: host, keychainUsername: "sotest",
              accountCacheDir: cacheDir,
              thumbnailCache: ThumbnailCache(client: client),
              tempCache: TempFileCache(limit: 4))
          await controller.signOut()
          #expect(fake.signOutCallCount == 1)
          #expect(try KeychainSID.load(host: host, username: "sotest") == nil)
          #expect(FileManager.default.fileExists(atPath: dummy.path) == false)
          #expect(auth.phase == .loggedOut)
          try? FileManager.default.removeItem(at: cacheDir)
      }

      @Test func signOutIsIdempotentWhenAlreadyLoggedOut() async {
          let fake = FakePhotosCore()
          let client = PhotosCoreClient(core: fake)
          let auth = AuthStateMachine(client: client)
          let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("acct-cache-\(UUID())")
          let controller = SignOutController(
              client: client, auth: auth,
              keychainHost: "https://x:5001", keychainUsername: "none",
              accountCacheDir: cacheDir,
              thumbnailCache: ThumbnailCache(client: client),
              tempCache: TempFileCache(limit: 4))
          await controller.signOut()
          await controller.signOut()
          #expect(auth.phase == .loggedOut)
          #expect(fake.signOutCallCount == 2)
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/SignOutControllerTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'SignOutController' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/Session/SignOutController.swift`:
  ```swift
  import Foundation
  import PhotosCore

  /// Clean single-account teardown (locked decision):
  ///  1. server logout via core (idempotent),
  ///  2. clear this account's Keychain SID,
  ///  3. wipe this account's local cache directory,
  ///  4. clear in-memory + temp caches,
  ///  5. return the app to the login phase.
  @MainActor
  final class SignOutController {
      private let client: PhotosCoreClient
      private let auth: AuthStateMachine
      private let keychainHost: String
      private let keychainUsername: String
      private let accountCacheDir: URL
      private let thumbnailCache: ThumbnailCache
      private let tempCache: TempFileCache

      init(client: PhotosCoreClient, auth: AuthStateMachine,
           keychainHost: String, keychainUsername: String,
           accountCacheDir: URL, thumbnailCache: ThumbnailCache, tempCache: TempFileCache) {
          self.client = client
          self.auth = auth
          self.keychainHost = keychainHost
          self.keychainUsername = keychainUsername
          self.accountCacheDir = accountCacheDir
          self.thumbnailCache = thumbnailCache
          self.tempCache = tempCache
      }

      func signOut() async {
          try? await client.signOut()
          try? KeychainSID.clear(host: keychainHost, username: keychainUsername)
          if let items = try? FileManager.default.contentsOfDirectory(at: accountCacheDir, includingPropertiesForKeys: nil) {
              for item in items { try? FileManager.default.removeItem(at: item) }
          }
          await thumbnailCache.invalidate(assetId: -1)
          await tempCache.clearAll()
          auth.reset()
      }
  }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/SignOutControllerTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'SignOutControllerTests' passed`, 2 tests. The Keychain assertions need a login keychain; on headless CI, run on the local Mac.
- [ ] Commit:
  ```
  git add app && git commit -m "Add sign out controller with server logout, Keychain and cache teardown"
  ```

---

### Task 53: App entry wiring (`SynologyPhotosApp` root state, RootRouter, Library scene)

**Files**
- Modify: `app/SynologyPhotos/SynologyPhotosApp.swift`
- Create: `app/SynologyPhotos/RootView.swift`
- Create: `app/SynologyPhotosTests/RootRouterTests.swift`

**Interfaces**
- Consumes: every Group D type above; the real `PhotosCore` constructor (Task 32) `PhotosCore(dbDir:cacheDir:)`.
- Produces: `@MainActor @Observable final class AppEnvironment` holding `client`, `auth`, `dataSource`, `thumbnailCache`, `tempCache`, `crawl`, `spaceSelection`, `host`, `accountCacheDir`, with `init(core: PhotosCoreProtocol, accountCacheDir: URL, host: String)`; `enum RootRoute { case login, library }`; `struct RootRouter { static func route(for phase: AuthPhase) -> RootRoute }`; `struct RootView: View`; `struct LibraryView: View`.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosTests/RootRouterTests.swift`:
  ```swift
  import Testing
  import PhotosCore
  @testable import SynologyPhotos

  struct RootRouterTests {
      @Test func validPhaseRoutesToLibrary() {
          let route = RootRouter.route(for: .valid(Session(sid: "S", synoToken: nil, username: "u", deviceDid: nil)))
          #expect(route == .library)
      }
      @Test func loggedOutRoutesToLogin() { #expect(RootRouter.route(for: .loggedOut) == .login) }
      @Test func expiredRoutesToLogin() { #expect(RootRouter.route(for: .expired) == .login) }
      @Test func needsOtpRoutesToLogin() { #expect(RootRouter.route(for: .needsOtp(username: "u")) == .login) }
      @Test func invalidRoutesToLogin() { #expect(RootRouter.route(for: .invalid(message: "x")) == .login) }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/RootRouterTests 2>&1 | tail -20
  ```
  Expected: `cannot find 'RootRouter' in scope`.
- [ ] Minimal implementation `app/SynologyPhotos/RootView.swift`:
  ```swift
  import SwiftUI
  import PhotosCore

  enum RootRoute: Equatable { case login, library }

  struct RootRouter {
      static func route(for phase: AuthPhase) -> RootRoute {
          if case .valid = phase { return .library }
          return .login
      }
  }

  /// Owns the app's long-lived objects for one run. Built with a PhotosCoreProtocol
  /// so tests use FakePhotosCore; production passes the real PhotosCore (conforms via
  /// the extension in PhotosCoreProtocol.swift).
  @MainActor
  @Observable
  final class AppEnvironment {
      let client: PhotosCoreClient
      let auth: AuthStateMachine
      let dataSource: WindowedDataSource
      let thumbnailCache: ThumbnailCache
      let tempCache: TempFileCache
      let crawl: CrawlProgressModel
      let spaceSelection: SpaceSelection
      let host: String
      let accountCacheDir: URL

      init(core: PhotosCoreProtocol, accountCacheDir: URL, host: String) {
          let c = PhotosCoreClient(core: core)
          self.client = c
          self.auth = AuthStateMachine(client: c)
          self.dataSource = WindowedDataSource(client: c, space: .personal, pageSize: 200)
          self.thumbnailCache = ThumbnailCache(client: c)
          self.tempCache = TempFileCache(limit: 24)
          self.crawl = CrawlProgressModel(client: c)
          self.spaceSelection = SpaceSelection(current: .personal)
          self.host = host
          self.accountCacheDir = accountCacheDir
      }
  }

  struct RootView: View {
      @State var env: AppEnvironment

      var body: some View {
          switch RootRouter.route(for: env.auth.phase) {
          case .login: LoginView(auth: env.auth)
          case .library: LibraryView(env: env)
          }
      }
  }

  /// Library scene: space toggle + importing progress + grid + detail.
  struct LibraryView: View {
      let env: AppEnvironment
      @State private var controller: PhotoGridController

      init(env: AppEnvironment) {
          self.env = env
          _controller = State(initialValue: PhotoGridController(dataSource: env.dataSource, cache: env.thumbnailCache))
      }

      var body: some View {
          VStack(spacing: 8) {
              HStack {
                  SpaceToggleView(selection: env.spaceSelection, dataSource: env.dataSource) {
                      await controller.applySnapshot()
                  }
                  Spacer()
                  if !env.crawl.isComplete {
                      Text(env.crawl.statusText).accessibilityIdentifier("crawl.status")
                  }
                  Button("Sign Out") {
                      Task {
                          let so = SignOutController(
                              client: env.client, auth: env.auth,
                              keychainHost: env.host,
                              keychainUsername: currentUsername(),
                              accountCacheDir: env.accountCacheDir,
                              thumbnailCache: env.thumbnailCache, tempCache: env.tempCache)
                          await so.signOut()
                      }
                  }
                  .accessibilityIdentifier("session.signout")
              }
              .padding(.horizontal, 12)
              if env.crawl.isComplete {
                  PhotoGridView(controller: controller)
              } else {
                  ProgressView(env.crawl.statusText).accessibilityIdentifier("crawl.progressview")
              }
          }
          .task {
              await env.crawl.startCrawl(space: env.spaceSelection.current)
              await env.dataSource.refreshCount()
              await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
              await controller.applySnapshot()
          }
      }

      /// The signed-in account username, read from the current auth phase.
      private func currentUsername() -> String {
          if case .valid(let session) = env.auth.phase { return session.username }
          return ""
      }
  }
  ```
  Then modify `app/SynologyPhotos/SynologyPhotosApp.swift` (replace the placeholder `ContentView` app from Task 8):
  ```swift
  import SwiftUI
  import PhotosCore

  @main
  struct SynologyPhotosApp: App {
      @State private var env: AppEnvironment

      init() {
          let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("SynologyNativePhotos")
          let dbDir = base.appendingPathComponent("db")
          let cacheDir = base.appendingPathComponent("cache")
          try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
          try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
          let core = try! PhotosCore(dbDir: dbDir.path, cacheDir: cacheDir.path)
          _env = State(initialValue: AppEnvironment(core: core, accountCacheDir: cacheDir, host: ""))
      }

      var body: some Scene {
          WindowGroup {
              RootView(env: env).frame(minWidth: 900, minHeight: 600)
          }
      }
  }
  ```
  Note: `try! PhotosCore(...)` in `init` compiles once the real xcframework is linked (Task 38). The unit-test target does not exercise `@main` and stays green against `FakePhotosCore`.
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/RootRouterTests 2>&1 | tail -15
  ```
  Expected: `Test Suite 'RootRouterTests' passed`, 5 tests.
- [ ] Commit:
  ```
  git add app && git commit -m "Wire app root routing between login and library scenes"
  ```

---

### Task 54: XCUITest suite (login, OTP, importing progress, grid, space toggle)

**Files**
- Modify: `app/SynologyPhotos/SynologyPhotosApp.swift` (honor a `--uitest-fake` launch argument)
- Create: `app/SynologyPhotos/UITestSupport/UITestFixture.swift`
- Create: `app/SynologyPhotosUITests/LibraryFlowUITests.swift` (replaces the `.gitkeep` placeholder from Task 8)

**Interfaces**
- Consumes: the a11y identifiers established above (`login.host/username/password/otp/submit/error`, `space.toggle`, `crawl.status`, `crawl.progressview`, `grid.collection`, `grid.cell.<id>`, `session.signout`).
- Produces: `enum UITestFixture { static func makeFakeCore() -> PhotosCoreProtocol }` (DEBUG only) and launch-arg handling in `AppEnvironment` construction.

**TDD steps**

- [ ] Write the failing test `app/SynologyPhotosUITests/LibraryFlowUITests.swift`:
  ```swift
  import XCTest

  final class LibraryFlowUITests: XCTestCase {
      private func launchFake() -> XCUIApplication {
          let app = XCUIApplication()
          app.launchArguments += ["--uitest-fake"]
          app.launch()
          return app
      }

      func testLoginThenImportingThenGrid() {
          let app = launchFake()
          let host = app.textFields["login.host"]
          XCTAssertTrue(host.waitForExistence(timeout: 5))
          host.click(); host.typeText("https://fake.local:5001")
          app.textFields["login.username"].click(); app.textFields["login.username"].typeText("photo")
          app.secureTextFields["login.password"].click(); app.secureTextFields["login.password"].typeText("pw")
          app.buttons["login.submit"].click()
          let otp = app.textFields["login.otp"]
          XCTAssertTrue(otp.waitForExistence(timeout: 5))
          otp.click(); otp.typeText("123456")
          app.buttons["login.submit"].click()
          XCTAssertTrue(app.otherElements["grid.collection"].waitForExistence(timeout: 10))
      }

      func testSpaceToggleReloadsGrid() {
          let app = launchFake()
          let host = app.textFields["login.host"]
          XCTAssertTrue(host.waitForExistence(timeout: 5))
          host.click(); host.typeText("https://fake.local:5001")
          app.textFields["login.username"].click(); app.textFields["login.username"].typeText("photo")
          app.secureTextFields["login.password"].click(); app.secureTextFields["login.password"].typeText("pw")
          app.buttons["login.submit"].click()
          let otp = app.textFields["login.otp"]
          XCTAssertTrue(otp.waitForExistence(timeout: 5))
          otp.click(); otp.typeText("123456"); app.buttons["login.submit"].click()
          XCTAssertTrue(app.otherElements["grid.collection"].waitForExistence(timeout: 10))
          let toggle = app.segmentedControls["space.toggle"]
          XCTAssertTrue(toggle.waitForExistence(timeout: 5))
          toggle.buttons["Shared"].click()
          XCTAssertTrue(app.otherElements["grid.collection"].waitForExistence(timeout: 10))
      }
  }
  ```
  Remove the placeholder: `rm app/SynologyPhotosUITests/.gitkeep`. Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-fail:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosUITests/LibraryFlowUITests 2>&1 | tail -30
  ```
  Expected: failure because `--uitest-fake` is not honored (login submit does not reach a fake, grid never appears) and `UITestFixture` does not exist.
- [ ] Minimal implementation `app/SynologyPhotos/UITestSupport/UITestFixture.swift`:
  ```swift
  import Foundation
  import PhotosCore

  /// Deterministic fixture core for XCUITests. Requires OTP on first login, then
  /// succeeds; seeds Personal (120) and Shared (30) assets, crawl complete.
  enum UITestFixture {
      #if DEBUG
      final class FakeUICore: PhotosCoreProtocol, @unchecked Sendable {
          private func asset(_ id: Int64, _ space: Space) -> Asset {
              Asset(id: id, cacheKey: "v", filename: "IMG_\(id).jpg", mediaKind: .photo,
                    takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
                    fileSize: nil, space: space, serverVersion: id)
          }
          func login(connection: Connection, username: String, password: String, otpCode: String?) async throws -> Session {
              if otpCode == nil { throw CoreError.OtpRequired }
              return Session(sid: "UITEST", synoToken: nil, username: username, deviceDid: nil)
          }
          func restoreSession(connection: Connection, session: Session) async throws -> SessionState { .valid }
          func signOut() async throws {}
          func probeCapabilities() async throws -> [ApiCapability] { [] }
          func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress {
              let total: UInt64 = space == .personal ? 120 : 30
              observer.onProgress(progress: CrawlProgress(space: space, done: total / 2, total: total, complete: false))
              return CrawlProgress(space: space, done: total, total: total, complete: true)
          }
          func reconcileDelta(space: Space) async throws -> CrawlProgress {
              CrawlProgress(space: space, done: 0, total: 0, complete: true)
          }
          func crawlProgress(space: Space) throws -> CrawlProgress {
              let total: UInt64 = space == .personal ? 120 : 30
              return CrawlProgress(space: space, done: total, total: total, complete: true)
          }
          func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
              let total = space == .personal ? 120 : 30
              let start = Int(offset); guard start < total else { return [] }
              let end = min(start + Int(limit), total)
              return (start..<end).map { asset(Int64($0), space) }
          }
          func assetCount(space: Space) throws -> UInt64 { space == .personal ? 120 : 30 }
          func fetchAlbums(space: Space) throws -> [Album] { [] }
          func thumbnail(space: Space, assetId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData {
              ThumbnailData(cachedPath: "", bytes: [])
          }
          func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String { "" }
      }
      static func makeFakeCore() -> PhotosCoreProtocol { FakeUICore() }
      #endif
  }
  ```
  Then modify `app/SynologyPhotos/SynologyPhotosApp.swift` `init()` to honor the launch argument:
  ```swift
      init() {
          let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("SynologyNativePhotos")
          let dbDir = base.appendingPathComponent("db")
          let cacheDir = base.appendingPathComponent("cache")
          try? FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
          try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
          let core: PhotosCoreProtocol
          #if DEBUG
          if ProcessInfo.processInfo.arguments.contains("--uitest-fake") {
              core = UITestFixture.makeFakeCore()
          } else {
              core = try! PhotosCore(dbDir: dbDir.path, cacheDir: cacheDir.path)
          }
          #else
          core = try! PhotosCore(dbDir: dbDir.path, cacheDir: cacheDir.path)
          #endif
          _env = State(initialValue: AppEnvironment(core: core, accountCacheDir: cacheDir, host: "https://fake.local:5001"))
      }
  ```
- [ ] Run-to-pass:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosUITests/LibraryFlowUITests 2>&1 | tail -25
  ```
  Expected: `Test Suite 'LibraryFlowUITests' passed`, 2 tests. Requires the app built and launchable; run on the local Mac, not headless CI without a window server.
- [ ] Commit:
  ```
  git add app && git commit -m "Add UI tests for login, OTP, importing progress, grid and space toggle"
  ```

---

## Cross-cutting close-out

### Task 55: Skip-guarded real NAS integration checklist (LAN and Tailscale)

**Files**
- Create: `app/SynologyPhotosTests/RealNASIntegrationTests.swift`

**Interfaces**
- Consumes: the real `PhotosCore` (post Task 38), `HostSelector` (Task 44), `ThumbnailCache` (Task 46), `PhotosCoreClient` (Task 40), `FfiCrawlObserver` (contract 2.4). Uses the cert DER captured in Task 12.
- Produces: `XCTSkip`-guarded XCTest cases (behind `RUN_REAL_NAS=1` and `NAS_*` env vars) covering close-out LAN e2e (Task 56) and Tailscale + cert pinning (Task 57). This is the automated harness those manual tasks drive.

**TDD steps**

- [ ] Write the skip-guarded test `app/SynologyPhotosTests/RealNASIntegrationTests.swift`:
  ```swift
  import XCTest
  import PhotosCore
  @testable import SynologyPhotos

  /// REAL NAS tests. Require a live Synology NAS at NAS_HOST with a dedicated
  /// Photos-only user (NAS_USER / NAS_PASS) and 2FA (NAS_OTP for one run).
  /// Skipped unless RUN_REAL_NAS=1. Run manually on the local Mac after Task 38.
  /// Covers LAN end-to-end (Task 56) and Tailscale + cert pinning (Task 57).
  final class RealNASIntegrationTests: XCTestCase {
      private func requireRealNAS() throws -> (host: String, user: String, pass: String, otp: String?) {
          let env = ProcessInfo.processInfo.environment
          try XCTSkipUnless(env["RUN_REAL_NAS"] == "1", "Set RUN_REAL_NAS=1 and NAS_* to run against a live NAS")
          return (env["NAS_HOST"] ?? "", env["NAS_USER"] ?? "", env["NAS_PASS"] ?? "", env["NAS_OTP"])
      }

      func testLanLoginCrawlGridThumbnailDetailSignOut() async throws {
          let cfg = try requireRealNAS()
          let base = FileManager.default.temporaryDirectory.appendingPathComponent("realnas-\(UUID())")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: base) }
          let core = try PhotosCore(dbDir: base.appendingPathComponent("db").path,
                                    cacheDir: base.appendingPathComponent("cache").path)
          let client = PhotosCoreClient(core: core)
          let conn = HostSelector.connection(for: .lan(cfg.host), pinnedCertDer: nil)
          _ = try await client.login(connection: conn, username: cfg.user, password: cfg.pass, otpCode: cfg.otp)
          _ = try await client.probeCapabilities()
          final class NoopObs: FfiCrawlObserver, @unchecked Sendable { func onProgress(progress: CrawlProgress) {} }
          let progress = try await client.crawlSpace(space: .personal, observer: NoopObs())
          XCTAssertTrue(progress.complete)
          let first = try client.fetchAssets(space: .personal, offset: 0, limit: 1)
          if let a = first.first {
              let cache = ThumbnailCache(client: client)
              let img = await cache.image(space: .personal, asset: a, size: .sm)
              XCTAssertNotNil(img, "thumbnail should decode for a real asset")
              let originalPath = try await client.downloadOriginal(space: .personal, assetId: a.id, cacheKey: a.cacheKey)
              XCTAssertTrue(FileManager.default.fileExists(atPath: originalPath))
          }
          try await client.signOut()
      }

      func testTailscaleLoginWithCertPinning() async throws {
          let cfg = try requireRealNAS()
          let env = ProcessInfo.processInfo.environment
          try XCTSkipUnless(env["NAS_TAILSCALE_HOST"] != nil && env["NAS_CERT_DER_PATH"] != nil,
                            "Set NAS_TAILSCALE_HOST and NAS_CERT_DER_PATH (captured in Task 12)")
          let der = try Data(contentsOf: URL(fileURLWithPath: env["NAS_CERT_DER_PATH"]!))
          let base = FileManager.default.temporaryDirectory.appendingPathComponent("realts-\(UUID())")
          try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: base) }
          let core = try PhotosCore(dbDir: base.appendingPathComponent("db").path,
                                    cacheDir: base.appendingPathComponent("cache").path)
          let client = PhotosCoreClient(core: core)
          let conn = HostSelector.connection(for: .tailscale(env["NAS_TAILSCALE_HOST"]!), pinnedCertDer: [UInt8](der))
          XCTAssertTrue(conn.verifyTls)
          _ = try await client.login(connection: conn, username: cfg.user, password: cfg.pass, otpCode: cfg.otp)
          try await client.signOut()
      }
  }
  ```
  Regenerate: `cd app && xcodegen generate`.
- [ ] Run-to-confirm-skip (default env; this is the automated "green" state):
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/RealNASIntegrationTests 2>&1 | tail -15
  ```
  Expected: both tests reported skipped ("Set RUN_REAL_NAS=1 ..."), suite passes with 0 failures.
- [ ] Commit:
  ```
  git add app && git commit -m "Add skip-guarded real NAS integration checklist for LAN and Tailscale runs"
  ```

---

### Task 56: LAN end-to-end run against the real NAS

**Files**
- Modify: `documentation/phase0-probe-results.md` (append a `## Close-out: LAN end-to-end` section with the run results)

**Interfaces**
- Consumes: the real xcframework (Task 38), the full app (Tasks 39 through 54), the dedicated Photos user (Task 3), Task 55's harness.
- Produces: a recorded LAN end-to-end pass covering login+2FA, crawl to barrier, grid, thumbnail, detail QuickLook (including HEIC/RAW/video format verification), space toggle, and sign out. Confirms the reverse-engineered API facts hold against the real NAS.

**Steps** (human-run on the local Mac)

- [ ] Verify absent:
  ```
  grep -q "## Close-out: LAN end-to-end" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `ABSENT`.
- [ ] Run the automated LAN harness:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && RUN_REAL_NAS=1 NAS_HOST='https://192.168.1.10:5001' NAS_USER='photosclient' NAS_PASS='...' NAS_OTP='123456' xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/RealNASIntegrationTests/testLanLoginCrawlGridThumbnailDetailSignOut 2>&1 | tail -20
  ```
  Expected: passes.
- [ ] Launch the built app against the LAN NAS and manually verify: login with the 2FA prompt, "importing N of M" progresses then the grid appears, thumbnails render, a detail QuickLook opens for a still/HEIC/RAW/video, the Personal/Shared toggle re-queries, and Sign Out returns to login with the Keychain SID cleared.
- [ ] Append a `## Close-out: LAN end-to-end` section to `documentation/phase0-probe-results.md` recording the DSM version, which formats previewed correctly in QuickLook, and any API deviation observed (escalate deviations for a contract amendment).
- [ ] Verify:
  ```
  grep -q "## Close-out: LAN end-to-end" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record LAN end-to-end verification against the real NAS"
  ```

---

### Task 57: Tailscale verification with cert pinning; confirm TLS never globally disabled

**Files**
- Modify: `documentation/phase0-probe-results.md` (append a `## Close-out: Tailscale + cert pinning` section)

**Interfaces**
- Consumes: the cert DER captured in Task 12, Task 55's Tailscale harness, `HostSelector` (Task 44), `transport.rs` pinning (Task 17).
- Produces: a recorded Tailscale-name login that succeeds via DER pinning with `verifyTls == true`, plus a grep-verified confirmation that no committed code path disables TLS validation globally.

**Steps** (human-run)

- [ ] Verify absent:
  ```
  grep -q "## Close-out: Tailscale + cert pinning" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `ABSENT`.
- [ ] Run the Tailscale harness:
  ```
  cd /Users/sahil/code/github/synology-native-photos/app && RUN_REAL_NAS=1 NAS_USER='photosclient' NAS_PASS='...' NAS_OTP='123456' NAS_TAILSCALE_HOST='https://nas.tailnet.ts.net:5001' NAS_CERT_DER_PATH='/path/to/nas-ts.der' xcodebuild test -project SynologyPhotos.xcodeproj -scheme SynologyPhotos -destination 'platform=macOS' -only-testing:SynologyPhotosTests/RealNASIntegrationTests/testTailscaleLoginWithCertPinning 2>&1 | tail -20
  ```
  Expected: passes; login over the Tailscale name succeeds because the DER is pinned, not because verification was disabled.
- [ ] Confirm no global TLS disable anywhere in committed code:
  ```
  grep -rn "danger_accept_invalid_certs" core/ app/ 2>/dev/null; echo "danger-refs-exit=$?"
  ```
  Expected: no matches (`danger-refs-exit=1`); if any match appears, it is a blocking defect to remove before sign-off.
- [ ] Append a `## Close-out: Tailscale + cert pinning` section recording: the Tailscale host used, that pinning succeeded with `verifyTls == true`, and the grep result proving no global disable.
- [ ] Verify:
  ```
  grep -q "## Close-out: Tailscale + cert pinning" documentation/phase0-probe-results.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`.
- [ ] Commit:
  ```
  git add documentation/phase0-probe-results.md
  git commit -m "Record Tailscale verification with cert pinning and TLS-never-disabled check"
  ```

---

### Task 58: Security audit of the read-only surface before Phase 1 sign-off

**Files**
- Create: `documentation/plans/2026-07-24-phase1-security-audit.md`

**Interfaces**
- Consumes: the full Phase 0/1 implementation (Tasks 1 through 57).
- Produces: a written audit of the read-only surface covering TLS trust, SID-in-Keychain, the absence of any write paths, and fail-closed handling of unexpected responses. Per the solo-developer workflow, "second pair of eyes" is satisfied by a fresh code-reviewer subagent dispatch or `/ultrareview`, not a human peer gate.

**Steps**

- [ ] Write the audit checklist and run each grep-backed check. Create `documentation/plans/2026-07-24-phase1-security-audit.md` with these sections and record the result of each command:
  1. TLS trust: `grep -rn "danger_accept_invalid_certs" core/ app/` returns nothing; `grep -rn "danger_accept_invalid_hostnames" core/` shows only the `false` form in `transport.rs`.
  2. No write paths: `grep -rniE "method=(delete|create|update|move|copy|rename|upload|set_)" core/` returns nothing outside `documentation/`; confirm no `PhotosCore` method mutates the NAS.
  3. Fail-closed: confirm `decode_envelope` maps unknown `error.code` to `UnexpectedResponse` (Task 16) and that `WriteRefused` exists but is never reached in P0/P1 (grep `WriteRefused` shows only the enum definition and its Swift mapping).
  4. Secrets: SID/SynoToken are stored only in the Keychain (Task 41), never written to the SQLite DB or logged; `grep -rn "sid" core/persistence/` returns no column storing it.
  5. Rate limiting: the client-side throttle (Task 17) is applied on every outbound request path (auth, info, browse, thumbnail, download).
- [ ] Dispatch a fresh code-reviewer subagent (or run `/ultrareview`) over the whole diff for the read-only surface and record its findings and resolutions in the audit doc.
- [ ] Verify the audit doc exists and every check has a recorded PASS/FAIL:
  ```
  test -f documentation/plans/2026-07-24-phase1-security-audit.md && echo PRESENT || echo ABSENT
  ```
  Expected: `PRESENT`, with no unresolved FAIL rows.
- [ ] Commit:
  ```
  git add documentation/plans/2026-07-24-phase1-security-audit.md
  git commit -m "Complete read-only surface security audit for Phase 1 sign-off"
  ```

---

## Plan Self-Review

Ran the writing-plans self-review over the assembled document and fixed issues inline.

**(a) Spec coverage.** Checked every locked design item and every contract section-5 task against a task in this plan. All 50 design items map to one of the 58 numbered tasks: Rust toolchain (1), workspace (2), dedicated DSM user (3), the four API probes + cert DER probe + delete-semantics probe (9 through 13), models types (5), photoscore scaffold (6), Makefile + committed bindings (7), Xcode project + FFI smoke test (8), the eight `synology-api` modules (14 through 23), the four persistence + two sync-engine units (24 through 31), the six `PhotosCore` facade methods + bindings regen (32 through 38), the sixteen Swift app units (39 through 54), and the four close-out tasks (55 through 58). No design item is unassigned.

**(b) Placeholder scan.** Grepped for `TBD`, `FIXME`, `XXX`, `similar to Task N`, `see above`, `add error handling`, and bare ellipses. The only survivors are legitimate prose (the word "placeholder" describing a test module to replace or the `.gitkeep` UI-test stub) and the intentional `pending`/`(record)` cells in the Phase 0 probe-results tables, which are human-fill fields by design. Removed the one genuinely confusing artifact: the illustrative `_ApiCapability` re-export line that had been embedded inside Task 32's code block with a "remove it" note; the code block is now directly usable and the note explains UniFFI type surfacing without dead code.

**(c) Type consistency.** Verified signatures are identical across every task and match the interface contract:
- `Asset` uses `file_size`/`server_version`/`cache_key`/`taken_at` in Rust and `fileSize`/`serverVersion`/`cacheKey`/`takenAt` in Swift consistently (15 Rust vs 6 Swift occurrences, all matching the same field set).
- `ThumbnailData.cached_path` (Rust) / `cachedPath` (Swift) balanced 6/6.
- `crawl_space` takes `observer: Box<dyn FfiCrawlObserver>` in Rust and `observer: FfiCrawlObserver` in Swift (the UniFFI callback-interface lowering), consistent across the facade task and all three Swift declarations plus the two fakes.
- `fetch_assets(space, offset: u32, limit: u32)` in Rust and `fetchAssets(space:offset:UInt32,limit:UInt32)` in Swift match at the persistence layer, the facade, the protocol, the client actor, and both fakes.
- `CoreError` has exactly the eight contract variants everywhere (`Auth`, `OtpRequired`, `Network`, `Decode`, `UnexpectedResponse`, `WriteRefused`, `Storage`, `CapabilityUnavailable`); the Swift `userMessage`/`isRetryable` switch is exhaustive over those eight.

**Fixes applied.**
1. Corrected Task 8's forward reference: the UI-test `.gitkeep` note now points to Task 54 (where `LibraryFlowUITests` lands), not the stale "Task 39".
2. Cleaned Task 32's code sample by removing the dead `_ApiCapability` re-export and narrowing the import list to what the task uses, with a note that Tasks 33 through 37 widen it as their signatures land.
3. Simplified Task 42's `restore` optional handling to a single `guard let stored = ..., let s = stored` unwrap.
4. Replaced em-dashes in the six section/task headings I authored with colons or commas to honor the no-dashes-as-dashes rule; the top-level document title retains its em-dash because the assembly spec mandated that exact string.

**Dependency ordering confirmed.** Tasks are numbered in strict dependency order: toolchain and scaffolding first (1 through 8), then the two independent Rust streams (`synology-api` 14 through 23 and persistence/sync-engine 24 through 31) which touch disjoint crates, then the facade wiring that consumes both frozen crate APIs (32 through 38), then the Swift app built against the frozen bindings through a protocol mock (39 through 54), then real-NAS close-out (55 through 58). Every task's Consumes references a Produces from an earlier-numbered task; the empirical NAS probes (3, 9 through 13) run in parallel and feed documentation, never blocking compilation because the contract is authoritative and decoding is tolerant.
