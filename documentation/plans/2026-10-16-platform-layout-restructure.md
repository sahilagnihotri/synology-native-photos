# Platform layout restructure

> **Status:** PLANNED. Run after the recycle bin check (W9) is verified and pushed.

## Why

The repo is about to gain a Windows app. Today the layout does not say what is
shared and what is Mac only:

- `app/` is the macOS app, but its name says nothing about the platform.
- `bindings/` holds generated Swift bindings (tracked) at the root, as if shared.
- `PhotosCore.xcframework` is a Mac build output sitting at the repo root.
- `scripts/` mixes Mac only steps (xcodegen, dmg, xcodebuild) with shared ones (cargo).
- Docs and `CLAUDE.md` describe a Mac only world.

## Target layout

```
core/                       shared Rust core (unchanged crate layout)
  models/ persistence/ photoscore/ sync-engine/ synology-api/
platforms/
  macos/                    the current app/ (Xcode project, project.yml, sources, tests)
    Generated/              Swift bindings + modulemap (was bindings/), still tracked
  windows/                  placeholder README: UI technology decision pending
build/                      ALL build outputs, gitignored
  macos/PhotosCore.xcframework
  macos/dist/               dmg output
scripts/
  shared/                   cargo test, clippy, fmt, common.sh
  macos/                    xcframework, xcodegen, dmg, xcodebuild test
  windows/                  placeholder for the Windows build
  test.sh                   top level dispatcher: core | macos | windows | all
documentation/
  architecture.md           one page: core, FFI boundary, platform apps
  platforms/macos.md, platforms/windows.md
```

## Rules for the move

1. `git mv` only, so history follows the files. One logical commit per step,
   each leaving `cargo test --workspace` and the Swift unit tests green.
2. Update every path reference: `Makefile`, `project.yml` (then regenerate the
   `.xcodeproj` with xcodegen, outside the sandbox), `scripts/**`, `.gitignore`,
   `README`, `HANDOVER.md`, `CLAUDE.md`, `TODO.md`, test scripts.
3. A grep for the old paths (`app/`, `bindings/`, `PhotosCore.xcframework` at the
   root) must come back empty, apart from git history and `documentation/plans/done`.
4. `scripts/test.sh` keeps working, with the new target names and the old ones
   kept as aliases for one release.
5. Add a CI workflow (GitHub Actions) that runs the core tests on `macos-latest`
   and `windows-latest`. GitHub Actions minutes are used up, so it must never run
   on its own: `on: workflow_dispatch` ONLY (no push, pull_request or schedule
   triggers), and every job guarded with `if: github.ref == 'refs/heads/stable'`
   so a manual run from any other branch does nothing. The `stable` branch does
   not exist yet; creating it is Sahil's call. Day to day Windows checks of the
   core run locally instead: `cargo check --target x86_64-pc-windows-msvc`
   (cargo-xwin) from the Mac, wrapped in `scripts/windows/check-core.sh`.

## Steps (one commit each)

1. Move build outputs under `build/` (Makefile, ensure-xcframework, .gitignore).
2. Move `bindings/` to `platforms/macos/Generated/` (Makefile, project.yml, regenerate).
3. Move `app/` to `platforms/macos/` (project.yml, scripts, test.sh).
4. Split `scripts/` into shared, macos, windows, keeping test.sh as the entry point.
5. Docs: architecture.md, platform pages, README, HANDOVER, CLAUDE.md paths.
6. Local CI scripts, the real source of truth (GitHub only ever calls these):
   - `scripts/ci/ci.sh` (macOS, and Linux for the core): `cargo fmt --check`,
     `cargo clippy --workspace --all-targets -- -D warnings`,
     `cargo test --workspace`, the shell script tests under `scripts/tests/`, and on
     macOS the Swift unit tests (ad hoc signed, test timeouts on) with pass, fail
     and skip counts read from the xcresult. Exit code is the gate; each stage
     prints PASS or FAIL and a summary table at the end. Stages selectable:
     `ci.sh core|macos|all`.
   - `scripts/ci/ci.ps1` (Windows, PowerShell): the same core stages, plus the
     Windows app stage once that app exists. Written now for the core so the
     Windows machine has a working gate on day one.
   - `scripts/windows/check-core.sh` (macOS): cross `cargo check` of the core for
     `x86_64-pc-windows-msvc` via cargo-xwin, so Windows breakage in the core is
     caught on the Mac. If cargo-xwin is missing it says how to install it.
7. Manual only GitHub workflow (`workflow_dispatch`, `stable` branch guard) that
   just runs `scripts/ci/ci.sh` on `macos-latest` and `scripts/ci/ci.ps1` on
   `windows-latest`.
8. Windows handover: `documentation/platforms/windows-handover.md`, a prompt to
   paste into Claude Code on the Windows machine once the Mac work is done. It
   states what exists, the layout, how to clone and set up (rustup, MSVC build
   tools), how to run `ci.ps1`, the NAS connection facts and OTP and device token
   approach from `CLAUDE.md`, the safety invariants, the open UI technology
   decision with the trade offs, and the first milestone (read only browse).

## Open decision (Sahil)

The Windows UI technology: WinUI 3 in C# over a C ABI, or a Rust native UI.
The layout above does not depend on it. A short decision document comes next.
