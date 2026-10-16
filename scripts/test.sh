#!/usr/bin/env bash
# Run the test suite for synology-native-photos, one command.
# A thin dispatcher: the real steps live in scripts/shared (core) and
# scripts/<platform> (apps), so CI and humans run the same code.
#
# Usage:
#   scripts/test.sh                  # everything that applies on this host
#   scripts/test.sh core             # Rust core tests only (any platform)
#   scripts/test.sh macos            # macOS app unit tests only
#   scripts/test.sh windows          # Windows app tests (no app yet, so a no-op)
#   scripts/test.sh app              # old name for macos, kept as an alias for now
#   ADHOC_SIGN=1 scripts/test.sh macos      # signed ad hoc (no keychain access)
#   scripts/test.sh --include-integration   # also run #[ignore]'d real NAS tests
#                                            # (needs SYNO_* env vars set)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared/common.sh
. "$SCRIPT_DIR/shared/common.sh"

WHAT="all"
CORE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    core|macos|windows|all) WHAT="$arg" ;;
    app) warn "'app' is the old name for 'macos'; use 'macos'."; WHAT="macos" ;;
    --include-integration) CORE_ARGS+=(--include-integration) ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

run_core()  { "$SCRIPT_DIR/shared/test-core.sh" ${CORE_ARGS[@]+"${CORE_ARGS[@]}"}; }

run_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    warn "macOS app tests need a Mac; skipping."
    return 0
  fi
  "$SCRIPT_DIR/macos/test-app.sh"
}

run_windows() {
  step "Windows app tests"
  warn "there is no Windows app yet (platforms/windows); nothing to test."
}

case "$WHAT" in
  core)    run_core ;;
  macos)   run_macos ;;
  windows) run_windows ;;
  all)     run_core; echo; run_macos; echo; run_windows ;;
esac

echo
ok "Test run complete."
