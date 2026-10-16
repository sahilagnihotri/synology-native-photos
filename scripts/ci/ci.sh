#!/usr/bin/env bash
# Local CI gate for synology-native-photos. This script is the source of
# truth: the GitHub workflow only ever calls it, so a green run here means the
# same as a green run there.
#
# Stages:
#   core   fmt       cargo fmt --all --check
#          clippy    cargo clippy --workspace --all-targets -- -D warnings
#          test      cargo test --workspace
#          scripts   every scripts/tests/test-*.sh
#   macos  swift     macOS app unit tests (ad hoc signed, test timeouts on),
#                    pass, fail and skip counts read from the xcresult
#
# Usage:
#   scripts/ci/ci.sh            # all (core, plus macos on a Mac)
#   scripts/ci/ci.sh core       # core stages only (macOS or Linux)
#   scripts/ci/ci.sh macos      # Swift unit tests only
#
# Every stage runs even after an earlier one fails, then a summary table is
# printed. The exit code is the gate: 0 when every stage passed, 1 when any
# failed, 2 on bad usage. A skipped Swift test counts as a failure, because a
# skipped run looks just like a passing one.
#
# CI_ROOT=<dir> runs the core stages against another Cargo workspace instead
# of this repo. scripts/tests/test-ci.sh uses it to prove the gate fails on a
# failing tree without touching the real one.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
. "$SCRIPT_DIR/../shared/common.sh"
# common.sh turns on errexit; the gate must keep going after a failed stage.
set +e

REPO="$(repo_root)"
ROOT="${CI_ROOT:-$REPO}"
WHAT="${1:-all}"
case "$WHAT" in
  core|macos|all) ;;
  *) err "usage: $(basename "$0") [core|macos|all]"; exit 2 ;;
esac

IS_MAC=0
[ "$(uname -s)" = "Darwin" ] && IS_MAC=1

STAGE_NAMES=()
STAGE_RESULTS=()
STAGE_NOTES=()
FAILED=0

record() {  # record <name> <PASS|FAIL|SKIP> [note]
  STAGE_NAMES+=("$1"); STAGE_RESULTS+=("$2"); STAGE_NOTES+=("${3:-}")
  case "$2" in
    PASS) printf '%s\n' "${_C_GRN}PASS${_C_RESET} $1 ${3:-}" ;;
    SKIP) printf '%s\n' "${_C_YLW}SKIP${_C_RESET} $1 ${3:-}" ;;
    *)    printf '%s\n' "${_C_RED}FAIL${_C_RESET} $1 ${3:-}"; FAILED=1 ;;
  esac
}

# run_stage <name> <command...>: runs the command from ROOT, records the result.
run_stage() {
  local name="$1"; shift
  step "== $name: $*"
  ( cd "$ROOT" && "$@" )
  if [ $? -eq 0 ]; then record "$name" PASS; else record "$name" FAIL; fi
}

stage_scripts() {
  local t n=0 bad=0
  step "== scripts: scripts/tests/test-*.sh"
  for t in "$ROOT"/scripts/tests/test-*.sh; do
    [ -f "$t" ] || continue
    n=$((n + 1))
    info "$(basename "$t")"
    if ! bash "$t"; then
      err "$(basename "$t") failed"
      bad=$((bad + 1))
    fi
  done
  if [ "$n" -eq 0 ]; then
    record scripts SKIP "(no script tests found)"
  elif [ "$bad" -eq 0 ]; then
    record scripts PASS "($n scripts)"
  else
    record scripts FAIL "($bad of $n scripts failed)"
  fi
}

run_core() {
  load_cargo_env
  if ! have cargo; then
    record core FAIL "(cargo not found; run scripts/macos/setup.sh or install rustup)"
    return
  fi
  run_stage fmt cargo fmt --all --check
  run_stage clippy cargo clippy --workspace --all-targets -- -D warnings
  run_stage test cargo test --workspace
  stage_scripts
}

run_macos() {
  if [ "$IS_MAC" -ne 1 ]; then
    record swift SKIP "(not a Mac)"
    return
  fi
  local bundle summary counts passed failed skipped total
  bundle="$REPO/build/macos/ci/unit-tests.xcresult"
  mkdir -p "$(dirname "$bundle")"
  step "== swift: scripts/macos/test-app.sh (ad hoc signed)"
  ADHOC_SIGN=1 RESULT_BUNDLE="$bundle" "$REPO/scripts/macos/test-app.sh"
  local rc=$?
  if [ ! -d "$bundle" ]; then
    record swift FAIL "(xcodebuild exit $rc, no xcresult written)"
    return
  fi
  summary="$(xcrun xcresulttool get test-results summary --path "$bundle" 2>/dev/null)"
  # The python3 first on PATH can be a broken toolchain shim; the system one is reliable.
  counts="$(printf '%s' "$summary" | /usr/bin/python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("totalTestCount", 0), d.get("passedTests", 0), d.get("failedTests", 0), d.get("skippedTests", 0))
' 2>/dev/null)"
  if [ -z "$counts" ]; then
    record swift FAIL "(xcodebuild exit $rc, could not read the xcresult summary)"
    return
  fi
  read -r total passed failed skipped <<< "$counts"
  local note="(passed $passed, failed $failed, skipped $skipped, total $total)"
  if [ "$rc" -eq 0 ] && [ "$failed" -eq 0 ] && [ "$skipped" -eq 0 ] && [ "$total" -gt 0 ]; then
    record swift PASS "$note"
  else
    record swift FAIL "$note xcodebuild exit $rc"
  fi
}

case "$WHAT" in
  core)  run_core ;;
  macos) run_macos ;;
  all)   run_core; [ "$IS_MAC" -eq 1 ] && run_macos ;;
esac

echo
step "CI summary ($WHAT)"
printf '  %-8s %-6s %s\n' STAGE RESULT NOTE
for i in "${!STAGE_NAMES[@]}"; do
  printf '  %-8s %-6s %s\n' "${STAGE_NAMES[$i]}" "${STAGE_RESULTS[$i]}" "${STAGE_NOTES[$i]}"
done
echo
if [ "$FAILED" -ne 0 ]; then
  printf '%s\n' "${_C_RED}${_C_BOLD}CI FAIL${_C_RESET}"
  exit 1
fi
printf '%s\n' "${_C_GRN}${_C_BOLD}CI PASS${_C_RESET}"
