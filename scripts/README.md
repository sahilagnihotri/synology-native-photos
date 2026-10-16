# Scripts

Replicable dev environment and test entry points. One install script per platform.

## Setup

```bash
scripts/macos/setup.sh            # install anything missing, then verify
scripts/macos/setup.sh --verify   # doctor mode: check only, install nothing
```

```powershell
pwsh scripts/windows/setup.ps1            # core toolchain only (UI is a future phase)
pwsh scripts/windows/setup.ps1 -Verify    # doctor mode
```

What macOS setup covers (idempotent, safe to re-run):
- Homebrew is the preferred installer on macOS. Setup verifies brew is present and uses it; if brew is missing it falls back to direct installers.
- Rust via `brew install rustup` (the toolchain manager, not `brew install rust`, which conflicts with rustup on PATH and cannot add cross-targets), then `rustup` adds the `aarch64-apple-darwin` target. Falls back to the official rustup-init installer when brew is absent.
- Project-driven UniFFI bindgen prerequisites (no fragile global install; bindgen runs via `cargo run` inside the core crate once scaffolded).
- Verifies Xcode 26+ and Swift 6.3+ (does not install Xcode; that comes from the App Store).
- Optional dev tools via brew (`xcpretty` for readable test output; `test.sh` uses it if present).
- `--verify` doctor mode prints a green/red report and exits non-zero on any failure.

## Test

```bash
scripts/test.sh                        # everything that applies on this host
scripts/test.sh core                   # Rust core tests only (any platform)
scripts/test.sh macos                  # macOS app unit tests only
scripts/test.sh windows                # Windows app tests (no app yet, a no-op)
scripts/test.sh app                    # old name for macos, kept as an alias
scripts/test.sh --include-integration  # also run real NAS tests (needs SYNO_* env vars)
```

Self-healing: if the Rust toolchain is missing on a Mac, the core tests run setup first.

## CI (local gate)

```bash
scripts/ci/ci.sh               # fmt, clippy, cargo test, script tests, Swift unit tests
scripts/ci/ci.sh core          # core stages only (macOS or Linux)
scripts/ci/ci.sh macos         # Swift unit tests only, counts read from the xcresult
scripts/windows/check-core.sh  # cross check the core for x86_64-pc-windows-msvc (needs cargo-xwin)
```

```powershell
pwsh scripts/ci/ci.ps1 core    # the same core stages on Windows
```

The exit code is the gate. The GitHub workflow is manual only and just calls these.

## Layout

```
scripts/
  shared/common.sh           shared bash helpers (colored output, version checks, verify accumulator)
  shared/test-core.sh        cargo test for the Rust core (any platform)
  macos/setup.sh             macOS dev setup + doctor mode
  macos/test-app.sh          xcodebuild unit tests for the macOS app
  macos/ffi-smoke.sh         Swift to Rust FFI smoke test against the built xcframework
  macos/xcodegen/            Xcode build phase helpers (xcframework self heal, GitVersion)
  macos/package/             dmg installer packaging
  windows/setup.ps1          Windows core toolchain setup (UI deferred)
  windows/check-core.sh      Windows cross check of the core from a Mac (cargo-xwin)
  ci/ci.sh, ci/ci.ps1        local CI gate (macOS and Linux, Windows)
  tests/                     tests for the scripts themselves
  test.sh                    top level dispatcher: core | macos | windows | all
```
