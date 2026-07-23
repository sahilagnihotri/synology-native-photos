#!/usr/bin/env bash
# Shared helpers for setup and test scripts. Source this; do not execute directly.
# Platform-agnostic. Keep POSIX-friendly where practical (targets bash 3.2 on macOS).

set -euo pipefail

# ---- output ---------------------------------------------------------------
if [ -t 1 ]; then
  _C_RESET=$'\033[0m'; _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'
  _C_YLW=$'\033[33m'; _C_BLU=$'\033[34m'; _C_BOLD=$'\033[1m'
else
  _C_RESET=""; _C_RED=""; _C_GRN=""; _C_YLW=""; _C_BLU=""; _C_BOLD=""
fi

info()  { printf '%s\n' "${_C_BLU}==>${_C_RESET} $*"; }
ok()    { printf '%s\n' "${_C_GRN}  ok${_C_RESET} $*"; }
warn()  { printf '%s\n' "${_C_YLW}  ! ${_C_RESET} $*" >&2; }
err()   { printf '%s\n' "${_C_RED}  x ${_C_RESET} $*" >&2; }
step()  { printf '%s\n' "${_C_BOLD}$*${_C_RESET}"; }

# ---- verify-report accumulator --------------------------------------------
# Doctor mode collects pass/fail lines and prints a summary + exit code.
_VERIFY_FAILS=0
check_pass() { ok "$*"; }
check_fail() { err "$*"; _VERIFY_FAILS=$((_VERIFY_FAILS + 1)); }
verify_summary() {
  echo
  if [ "$_VERIFY_FAILS" -eq 0 ]; then
    printf '%s\n' "${_C_GRN}${_C_BOLD}All checks passed.${_C_RESET}"
    return 0
  fi
  printf '%s\n' "${_C_RED}${_C_BOLD}${_VERIFY_FAILS} check(s) failed.${_C_RESET}"
  return 1
}

# ---- utilities ------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Compare dotted versions: version_ge "6.3.3" "6.3" -> success (>=)
version_ge() {
  # returns 0 if $1 >= $2
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

# Repo root regardless of where the script is invoked from.
# Prefers git; falls back to walking up from this library's own location.
# Must be robust under both bash and zsh (BASH_SOURCE may be unset in zsh).
repo_root() {
  local here root
  # This file's directory: use BASH_SOURCE under bash, else the caller's PWD.
  if [ -n "${BASH_SOURCE:-}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  else
    here="$PWD"
  fi
  root="$(git -C "$here" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$root" ]; then
    printf '%s\n' "$root"
  else
    # Fallback: this lib lives at <root>/scripts/lib/common.sh
    ( cd "$here/../.." && pwd )
  fi
}

# Load cargo env into the current shell if present (rustup installs here).
load_cargo_env() {
  # shellcheck disable=SC1090
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true
}
