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

# --- --verify and the bindgen check, against a fake repo root ----------------
# bindgen_case <name> <create source 0|1> <args> <want text> <want cargo calls 0|1>
# Tolerant stubs (exit 0) so the script gets as far as the bindgen check.
mkdir -p "$BASE/bin2"
for t in brew rustup rustup-init curl cargo rustc xcodebuild swift; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$t" "$LOG" > "$BASE/bin2/$t"
  chmod +x "$BASE/bin2/$t"
done
bindgen_case() {
  local d="$BASE/root-$1"
  mkdir -p "$d/core/photoscore/src/bin"
  [ "$2" = "1" ] && : > "$d/core/photoscore/src/bin/uniffi-bindgen.rs"
  : > "$LOG"
  SETUP_REPO_ROOT="$d" HOME="$BASE/home" PATH="$BASE/bin2:/usr/bin:/bin" bash "$SETUP" $3 >"$BASE/out" 2>&1
  local cargo_calls; cargo_calls="$(grep -c '^cargo run' "$LOG")"
  local calls_ok=0
  if [ "$5" = "1" ] && [ "$cargo_calls" -gt 0 ]; then calls_ok=1; fi
  if [ "$5" = "0" ] && [ "$cargo_calls" -eq 0 ]; then calls_ok=1; fi
  if grep -q "$4" "$BASE/out" && [ "$calls_ok" -eq 1 ]; then
    echo "ok   $1"
  else
    echo "FAIL $1: wanted '$4' and cargo run calls=$5, got $cargo_calls calls"
    tail -5 "$BASE/out"
    fails=$((fails + 1))
  fi
}
bindgen_case "verify with the bindgen source missing reports it" 0 --verify "bindgen source missing" 0
bindgen_case "verify with the source present never runs cargo run" 1 --verify "source present" 0
bindgen_case "full setup still runs the bindgen bin" 1 "" "project uniffi-bindgen runs" 1

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
