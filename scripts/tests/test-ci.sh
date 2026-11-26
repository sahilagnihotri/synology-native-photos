#!/usr/bin/env bash
# Tests scripts/ci/ci.sh against throwaway Cargo workspaces under $TMPDIR, so
# the gate is shown to FAIL on a failing tree, not only to pass on a good one.
# Never touches the real repo: ci.sh is pointed at each fake tree via CI_ROOT,
# and the fake trees have no scripts/tests, so this does not recurse.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# CI_SCRIPT lets a mutated copy of ci.sh be checked against these same cases.
CI="${CI_SCRIPT:-$REPO/scripts/ci/ci.sh}"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/ci-gate.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
# Each fake tree builds into its own target/ under $BASE; a shared target dir
# lets cargo reuse one tree's build for another of the same crate name.
unset CARGO_TARGET_DIR

fails=0

# mk <name> <lib.rs body>: a one crate workspace pinned to the repo toolchain.
mk() {
  local d="$BASE/$1"
  mkdir -p "$d/src"
  cp "$REPO/rust-toolchain.toml" "$d/"
  printf '[package]\nname = "cigate"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n' > "$d/Cargo.toml"
  printf '%s\n' "$2" > "$d/src/lib.rs"
  # The gate runs with --locked, so a tree needs a lockfile unless a case is about its absence.
  [ "${NO_LOCK:-0}" = "1" ] || ( cd "$d" && cargo generate-lockfile --offline >/dev/null 2>&1 )
  echo "$d"
}

# expect <name> <exit code> <text the output must contain> <dir or "">
expect() {
  local out rc
  if [ -n "$4" ]; then
    out="$(CI_ROOT="$4" "$CI" core 2>&1)"; rc=$?
  else
    out="$("$CI" bogus 2>&1)"; rc=$?
  fi
  if [ "$rc" -eq "$2" ] && printf '%s' "$out" | grep -q "$3"; then
    echo "ok   $1"
  else
    echo "FAIL $1: wanted exit $2 and '$3', got exit $rc"
    printf '%s\n' "$out" | tail -15
    fails=$((fails + 1))
  fi
}

GOOD='pub fn add(a: i32, b: i32) -> i32 {
    a + b
}

#[cfg(test)]
mod tests {
    #[test]
    fn adds() {
        assert_eq!(super::add(2, 2), 4);
    }
}'

expect "good tree passes" 0 "^PASS test" "$(mk good "$GOOD")"
expect "failing test fails the gate" 1 "^FAIL test" "$(mk badtest "${GOOD/assert_eq!(super::add(2, 2), 4)/assert_eq!(super::add(2, 2), 5)}")"
expect "unformatted code fails the gate" 1 "^FAIL fmt" "$(mk badfmt "${GOOD/a + b/a+b}")"
expect "clippy warning fails the gate" 1 "^FAIL clippy" "$(mk badclippy "$GOOD
pub fn empty(v: &[i32]) -> bool {
    v.len() == 0
}")"
expect "good tree prints CI PASS" 0 "CI PASS" "$BASE/good"
expect "failing tree prints CI FAIL" 1 "CI FAIL" "$BASE/badtest"
expect "tree with zero tests fails the test stage" 1 "FAIL test .*no tests ran" "$(mk notests 'pub fn add(a: i32, b: i32) -> i32 {
    a + b
}')"
expect "tree without a lockfile fails the gate (--locked)" 1 "^FAIL clippy" "$(NO_LOCK=1 mk nolock "$GOOD")"
expect "good tree reports the passed count" 0 "PASS test (1 passed)" "$BASE/good"
expect "unknown stage is a usage error" 2 "usage" ""

# --- swift stage, driven with a stub test-app.sh and a fake xcrun on PATH ----
# swift_case <name> <stub exit code> <failed count> <skipped count> <total> <wanted exit> <wanted text>
if [ "$(uname -s)" = "Darwin" ]; then
  mkdir -p "$BASE/fakebin"
  cat > "$BASE/fakebin/xcrun" <<X
#!/bin/sh
printf '{"totalTestCount": %s, "passedTests": 1, "failedTests": %s, "skippedTests": %s}' "\$FAKE_TOTAL" "\$FAKE_FAILED" "\$FAKE_SKIPPED"
X
  chmod +x "$BASE/fakebin/xcrun"
  cat > "$BASE/stub-test-app.sh" <<'X'
#!/bin/sh
mkdir -p "$RESULT_BUNDLE"
exit "${FAKE_RC:-0}"
X
  chmod +x "$BASE/stub-test-app.sh"
  swift_case() {
    local out rc
    out="$(FAKE_RC="$2" FAKE_FAILED="$3" FAKE_SKIPPED="$4" FAKE_TOTAL="$5" CI_TEST_APP="$BASE/stub-test-app.sh" \
      CI_BUNDLE_DIR="$BASE/bundles/$1" PATH="$BASE/fakebin:$PATH" "$CI" macos 2>&1)"; rc=$?
    if [ "$rc" -eq "$6" ] && printf '%s' "$out" | grep -q "$7"; then
      echo "ok   swift: $1"
    else
      echo "FAIL swift: $1: wanted exit $6 and '$7', got exit $rc"
      printf '%s\n' "$out" | tail -8
      fails=$((fails + 1))
    fi
  }
  swift_case "passing run prints PASS" 0 0 0 5 0 "^PASS swift"
  swift_case "failing tests print FAIL" 1 2 0 5 1 "^FAIL swift"
  swift_case "nonzero xcodebuild exit with clean counts fails" 65 0 0 5 1 "^FAIL swift"
  swift_case "skipped test fails" 0 0 1 5 1 "^FAIL swift"
  swift_case "zero tests fails" 0 0 0 0 1 "^FAIL swift"
else
  echo "skip swift stage cases (not a Mac)"
fi

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
