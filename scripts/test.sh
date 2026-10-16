#!/usr/bin/env bash
# Run the full test suite for synology-native-photos, one command.
# Self-healing: if the Rust toolchain is missing, it runs setup first
# (per the project rule that dependent scripts fix their own prerequisites).
#
# Usage:
#   scripts/test.sh              # run everything present (core + app)
#   scripts/test.sh core         # Rust core tests only
#   scripts/test.sh app          # Swift/macOS app unit tests only
#   ADHOC_SIGN=1 scripts/test.sh app   # same, signed ad hoc (no keychain access)
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
  # The Cargo workspace manifest lives at the repo ROOT (members are the
  # crates under core/), not in a core/ subdirectory. Guard and run from root.
  if [ ! -f "$ROOT/Cargo.toml" ]; then
    warn "no Rust workspace at repo root yet (scaffold task not run); skipping core tests."
    return 0
  fi
  ( cd "$ROOT" && cargo test --workspace )
  if [ "$INCLUDE_INTEGRATION" -eq 1 ]; then
    step "Rust integration tests (real NAS)"
    : "${SYNO_HOST:?set SYNO_HOST to run integration tests}"
    ( cd "$ROOT" && cargo test --workspace -- --ignored )
  fi
  ok "core tests done"
}

run_app_tests() {
  step "Swift / macOS app tests"
  if [ -d "$ROOT/platforms/macos" ] && ls "$ROOT/platforms/macos"/*.xcodeproj >/dev/null 2>&1; then
    local proj scheme
    proj="$(ls -d "$ROOT/platforms/macos"/*.xcodeproj | head -n1)"
    scheme="$(basename "$proj" .xcodeproj)"
    # Unit tests only: the UI test target drives the app through System
    # Events, which raises an automation permission prompt on every run.
    # ADHOC_SIGN=1 signs ad hoc instead of with the team certificate, for
    # shells (such as a sandboxed agent) that cannot see the login keychain.
    local sign_args=()
    if [ "${ADHOC_SIGN:-0}" = "1" ]; then
      sign_args=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
    fi
    xcodebuild test \
      -project "$proj" \
      -scheme "$scheme" \
      -destination 'platform=macOS' \
      -only-testing:"${scheme}Tests" \
      ${sign_args[@]+"${sign_args[@]}"} \
      | { have xcpretty && xcpretty || cat; }
    ok "app tests done"
  elif [ -f "$ROOT/platforms/macos/Package.swift" ]; then
    ( cd "$ROOT/platforms/macos" && swift test )
    ok "app tests done (SwiftPM)"
  else
    warn "no Xcode project or Package.swift at platforms/macos/ yet; skipping app tests."
  fi
}

case "$WHAT" in
  core) run_core_tests ;;
  app)  run_app_tests ;;
  all)  run_core_tests; echo; run_app_tests ;;
esac

echo
ok "Test run complete."
