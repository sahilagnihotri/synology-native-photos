#!/usr/bin/env bash
# Run the shared Rust core tests (the Cargo workspace at the repo root,
# members under core/). Platform neutral: used by scripts/test.sh and CI.
#
# Self-healing: if cargo is missing on macOS it runs scripts/macos/setup.sh
# first (per the project rule that dependent scripts fix their own
# prerequisites). Elsewhere it says which setup script to run.
#
# Usage:
#   scripts/shared/test-core.sh                         # unit and mock tests
#   scripts/shared/test-core.sh --include-integration   # also the #[ignore]'d
#                                                       # real NAS tests (needs SYNO_* env vars)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

ROOT="$(repo_root)"
INCLUDE_INTEGRATION=0
for arg in "$@"; do
  case "$arg" in
    --include-integration) INCLUDE_INTEGRATION=1 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

step "Rust core tests"
load_cargo_env
if ! have cargo; then
  if [ "$(uname -s)" = "Darwin" ]; then
    warn "cargo missing; running setup to self-heal..."
    "$ROOT/scripts/macos/setup.sh"
    load_cargo_env
  else
    err "cargo not found. Install Rust (see rust-toolchain.toml) first."
    exit 1
  fi
fi
# The Cargo workspace manifest lives at the repo ROOT (members are the
# crates under core/), not in a core/ subdirectory. Guard and run from root.
if [ ! -f "$ROOT/Cargo.toml" ]; then
  warn "no Rust workspace at repo root; skipping core tests."
  exit 0
fi
( cd "$ROOT" && cargo test --workspace )
if [ "$INCLUDE_INTEGRATION" -eq 1 ]; then
  step "Rust integration tests (real NAS)"
  : "${SYNO_HOST:?set SYNO_HOST to run integration tests}"
  ( cd "$ROOT" && cargo test --workspace -- --ignored )
fi
ok "core tests done"
