# tasks.md — dispatch state

Live dispatch only. `TODO.md` says what needs doing; this file says who owns what right now.
Status: queued, in-progress, awaiting-verification, verified, abandoned.

## CURRENT (2026-11-26): full-repo review, fixes, Windows core check

Baseline at `1c2c107` (2026-11-26, this Mac now on macOS 27.0 and Xcode 27.2):
`scripts/ci/ci.sh core` PASS (fmt, clippy, Rust 385 passed, 0 failed, 1 ignored,
2 script tests). The Swift stage could NOT build: see B1.

Review workers are READ-ONLY on source. Each owns only its notes file.

| ID | Goal | Owned paths (write) | Reviews (read) | Status | Closes |
|----|------|---------------------|----------------|--------|--------|
| B1 | Release core build fails on macOS 27 with Xcode 27.2 | `Cargo.toml` | build scripts | in-progress (main) | BUILD-1 |
| R1 | Review the DSM API client | `agent-notes/r1-synology-api.md` | `core/synology-api/` | in-progress | REV-2026-11 |
| R2 | Review the FFI facade and sync engine | `agent-notes/r2-photoscore-sync.md` | `core/photoscore/`, `core/sync-engine/` | in-progress | REV-2026-11 |
| R3 | Review the local index and models | `agent-notes/r3-persistence-models.md` | `core/persistence/`, `core/models/` | in-progress | REV-2026-11 |
| R4 | Review app auth, session, caches, detail, trash, settings | `agent-notes/r4-app-auth-detail.md` | `platforms/macos/MySynologyPhotos/{Auth,Session,CoreBridge,Thumbnails,Detail,Trash,Settings,Reachability}/` and their tests | in-progress | REV-2026-11 |
| R5 | Review app grid, root, map, discovery, search, filter, menu, sidebar | `agent-notes/r5-app-grid-root.md` | `platforms/macos/MySynologyPhotos/{Grid,Map,Discovery,Search,Filter,Menu,Sidebar,About}/`, `RootView.swift`, app entry, their tests | in-progress | REV-2026-11 |
| R6 | Review scripts, Makefile, project.yml, bindings freshness, docs drift, repo hygiene | `agent-notes/r6-build-infra.md` | `scripts/{shared,macos,ci,tests}/`, `Makefile`, `platforms/macos/project.yml`, root docs | in-progress | REV-2026-11 |
| W1 | Windows core: run the cross check, fix the scripts and any core breakage | `scripts/windows/`, `scripts/ci/ci.ps1`, `rust-toolchain.toml`, `.gitattributes` | whole core | queued (main) | WIN-1 |

Fix tasks are added below once the findings are synthesized and verified.

Blocked on the user: DSM password change, `photosclient` user, a test album for album verification.
