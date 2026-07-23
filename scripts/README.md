# Scripts

Replicable dev environment and test entry points. One install script per platform.

## Setup

```bash
scripts/setup/macos.sh            # install anything missing, then verify
scripts/setup/macos.sh --verify   # doctor mode: check only, install nothing
```

```powershell
pwsh scripts/setup/windows.ps1            # core toolchain only (UI is a future phase)
pwsh scripts/setup/windows.ps1 -Verify    # doctor mode
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
scripts/test.sh                        # run everything present (core + app)
scripts/test.sh core                   # Rust core tests only
scripts/test.sh app                    # Swift/macOS app tests only
scripts/test.sh --include-integration  # also run real-NAS tests (needs SYNO_* env vars)
```

Self-healing: if the Rust toolchain is missing, `test.sh` runs setup first. Before the
scaffold tasks create `core/` and `app/`, the test script skips cleanly with a warning.

## Layout

```
scripts/
  lib/common.sh        shared bash helpers (colored output, version checks, verify accumulator)
  setup/macos.sh       macOS dev setup + doctor mode
  setup/windows.ps1    Windows core-toolchain setup (UI deferred)
  test.sh              run the full test suite, one command
```
