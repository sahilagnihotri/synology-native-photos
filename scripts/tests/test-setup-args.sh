#!/usr/bin/env bash
# Tests the argument handling of scripts/macos/setup.sh. Installer commands
# (brew, rustup, rustup-init, curl, cargo) are stubs earlier on PATH that only
# record a call, so a wrongly accepted argument cannot install anything.
# SETUP_SCRIPT lets a mutated copy of setup.sh be checked against these cases.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
SETUP="${SETUP_SCRIPT:-$REPO/scripts/macos/setup.sh}"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/setup-args.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/bin"
LOG="$BASE/calls.log"
for t in brew rustup rustup-init curl cargo rustc xcodebuild swift; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$t" "$LOG" > "$BASE/bin/$t"
  chmod +x "$BASE/bin/$t"
done
mkdir -p "$BASE/home"  # HOME points here so nothing real is read or written

fails=0
# expect <name> <exit code> <args...>
expect() {
  local name="$1" want="$2" rc; shift 2
  : > "$LOG"
  HOME="$BASE/home" PATH="$BASE/bin:/usr/bin:/bin" bash "$SETUP" "$@" >"$BASE/out" 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ] && [ ! -s "$LOG" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: wanted exit $want and no tool calls, got exit $rc, calls: $(tr '\n' ';' < "$LOG")"
    fails=$((fails + 1))
  fi
}

expect "unknown flag exits 2 and installs nothing" 2 --bogus
expect "typo of --verify exits 2" 2 --verfiy
expect "short flag exits 2" 2 -v
expect "--verify in second position exits 2" 2 --check --verify
expect "extra argument after --verify exits 2" 2 --verify extra
expect "--help exits 0 and installs nothing" 0 --help

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
