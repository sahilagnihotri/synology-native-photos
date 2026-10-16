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
expect "unknown stage is a usage error" 2 "usage" ""

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
