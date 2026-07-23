#!/usr/bin/env bash
# Run the full test suite for synology-native-photos, one command.
# Self-healing: if the Rust toolchain is missing, it runs setup first
# (per the project rule that dependent scripts fix their own prerequisites).
#
# Usage:
#   scripts/test.sh              # run everything present (core + app)
#   scripts/test.sh core         # Rust core tests only
#   scripts/test.sh app          # Swift/macOS app tests only
#   scripts/test.sh --include-integration   # also run #[ignore]'d real-NAS tests
#                                            # (needs SYNO_* env vars set)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
WHAT="all"
INCLUDE_INTEGRATION=0
for arg in "$@"; do
  case "$arg" in
    core|app|all) WHAT="$arg" ;;
    --include-integration) INCLUDE_INTEGRATION=1 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

run_core_tests() {
  step "Rust core tests"
  load_cargo_env
  if ! have cargo; then
    warn "cargo missing; running setup to self-heal..."
    "$SCRIPT_DIR/setup/macos.sh"
    load_cargo_env
  fi
  if [ ! -f "$ROOT/core/Cargo.toml" ] && [ ! -f "$ROOT/core/Cargo.lock" ]; then
    warn "no Rust workspace at core/ yet (scaffold task not run); skipping core tests."
    return 0
  fi
  ( cd "$ROOT/core" && cargo test --workspace )
  if [ "$INCLUDE_INTEGRATION" -eq 1 ]; then
    step "Rust integration tests (real NAS)"
    : "${SYNO_HOST:?set SYNO_HOST to run integration tests}"
    ( cd "$ROOT/core" && cargo test --workspace -- --ignored )
  fi
  ok "core tests done"
}

run_app_tests() {
  step "Swift / macOS app tests"
  if [ -d "$ROOT/app" ] && ls "$ROOT/app"/*.xcodeproj >/dev/null 2>&1; then
    local proj scheme
    proj="$(ls -d "$ROOT/app"/*.xcodeproj | head -n1)"
    scheme="$(basename "$proj" .xcodeproj)"
    xcodebuild test \
      -project "$proj" \
      -scheme "$scheme" \
      -destination 'platform=macOS' \
      | { have xcpretty && xcpretty || cat; }
    ok "app tests done"
  elif [ -f "$ROOT/app/Package.swift" ]; then
    ( cd "$ROOT/app" && swift test )
    ok "app tests done (SwiftPM)"
  else
    warn "no Xcode project or Package.swift at app/ yet; skipping app tests."
  fi
}

case "$WHAT" in
  core) run_core_tests ;;
  app)  run_app_tests ;;
  all)  run_core_tests; echo; run_app_tests ;;
esac

echo
ok "Test run complete."
