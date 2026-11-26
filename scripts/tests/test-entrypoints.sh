#!/usr/bin/env bash
# Tests that the test entry points fail closed: scripts/test.sh rejects an
# unknown argument, and scripts/macos/test-app.sh refuses to succeed when there
# is no Xcode project. A stub xcodebuild records any call, so nothing real runs.
# TEST_SH and TEST_APP_SH let mutated copies be checked against these cases.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TEST_SH="${TEST_SH:-$REPO/scripts/test.sh}"
TEST_APP_SH="${TEST_APP_SH:-$REPO/scripts/macos/test-app.sh}"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/entrypoints.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/bin" "$BASE/emptyapp"
LOG="$BASE/calls.log"
for t in xcodebuild cargo; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$t" "$LOG" > "$BASE/bin/$t"
  chmod +x "$BASE/bin/$t"
done
export PATH="$BASE/bin:$PATH"

fails=0
check() {  # check <name> <wanted rc> <actual rc> <text the output must contain>
  if [ "$2" -eq "$3" ] && grep -q "$4" "$BASE/out" && [ ! -s "$LOG" ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: wanted exit $2, got $3; calls: $(tr '\n' ';' < "$LOG")"
    fails=$((fails + 1))
  fi
}

: > "$LOG"
bash "$TEST_SH" --include-integraton >"$BASE/out" 2>&1; rc=$?
check "test.sh rejects a mistyped flag with exit 2" 2 "$rc" "unknown argument"

: > "$LOG"
APP_DIR_OVERRIDE="$BASE/emptyapp" bash "$TEST_APP_SH" >"$BASE/out" 2>&1; rc=$?
check "test-app.sh fails when there is no Xcode project" 1 "$rc" "no Xcode project"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
