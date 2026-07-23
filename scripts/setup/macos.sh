#!/usr/bin/env bash
# macOS development setup for synology-native-photos.
# Idempotent: safe to re-run. Installs/verifies the Rust toolchain, the
# project-driven UniFFI bindgen prerequisites, and checks Xcode/Swift.
#
# Usage:
#   scripts/setup/macos.sh            # install anything missing, then verify
#   scripts/setup/macos.sh --verify   # doctor mode: check only, install nothing
#
# Version floors (from the design's Global Constraints):
#   Xcode 26+, Swift 6.3+, Rust stable via rustup, target aarch64-apple-darwin.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

VERIFY_ONLY=0
[ "${1:-}" = "--verify" ] && VERIFY_ONLY=1

MIN_XCODE="26.0"
MIN_SWIFT="6.3"
RUST_TARGET="aarch64-apple-darwin"

# --- platform guard --------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  err "This script is for macOS. On Windows use scripts/setup/windows.ps1."
  exit 1
fi

# --- 1. Xcode + Swift (verify only; Xcode comes from the App Store) --------
check_xcode() {
  step "Xcode & Swift"
  if ! have xcodebuild; then
    check_fail "xcodebuild not found. Install Xcode $MIN_XCODE+ from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app"
    return
  fi
  local xver
  xver="$(xcodebuild -version 2>/dev/null | awk '/^Xcode/{print $2}')"
  if [ -n "$xver" ] && version_ge "$xver" "$MIN_XCODE"; then
    check_pass "Xcode $xver (>= $MIN_XCODE)"
  else
    check_fail "Xcode $xver found, need >= $MIN_XCODE"
  fi

  if ! have swift; then
    check_fail "swift not found on PATH"
    return
  fi
  local sver
  sver="$(swift --version 2>/dev/null | sed -nE 's/.*Swift version ([0-9.]+).*/\1/p' | head -n1)"
  if [ -n "$sver" ] && version_ge "$sver" "$MIN_SWIFT"; then
    check_pass "Swift $sver (>= $MIN_SWIFT)"
  else
    check_fail "Swift $sver found, need >= $MIN_SWIFT"
  fi
}

# --- 2. Rust toolchain -----------------------------------------------------
# Prefer Homebrew on macOS: install rustup via brew, then let rustup manage the
# toolchain and targets. We deliberately install `rustup` (the manager), NOT
# `brew install rust`, because a brew-managed rust conflicts with rustup on PATH
# and cannot add cross-compilation targets. If brew is absent, fall back to the
# official rustup-init installer.
ensure_rust() {
  step "Rust toolchain"
  load_cargo_env
  if have rustc && have cargo; then
    check_pass "rustc $(rustc --version | awk '{print $2}'), cargo present"
  elif [ "$VERIFY_ONLY" -eq 1 ]; then
    check_fail "Rust not installed. Run scripts/setup/macos.sh (without --verify) to install."
    return
  elif have brew; then
    info "Installing rustup via Homebrew..."
    brew list rustup >/dev/null 2>&1 || brew install rustup
    # brew's rustup is keg-only; initialize the default toolchain.
    rustup default stable 2>/dev/null || rustup-init -y --default-toolchain stable --no-modify-path
    load_cargo_env
    have rustc && check_pass "rustc $(rustc --version | awk '{print $2}') installed (via brew rustup)" \
      || check_fail "rustup installed but rustc not on PATH; ensure ~/.cargo/bin is in PATH"
  else
    warn "Homebrew not found; falling back to the official rustup installer."
    info "Installing Rust via rustup (stable)..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --default-toolchain stable --profile default
    load_cargo_env
    have rustc && check_pass "rustc $(rustc --version | awk '{print $2}') installed" \
      || check_fail "Rust install did not put rustc on PATH"
  fi

  # target
  if rustup target list --installed 2>/dev/null | grep -q "^${RUST_TARGET}$"; then
    check_pass "target $RUST_TARGET present"
  elif [ "$VERIFY_ONLY" -eq 1 ]; then
    check_fail "target $RUST_TARGET missing"
  else
    info "Adding target $RUST_TARGET..."
    rustup target add "$RUST_TARGET"
    check_pass "target $RUST_TARGET added"
  fi
}

# --- 3. UniFFI bindgen (project-driven, not a global install) --------------
# Modern UniFFI is driven from inside the crate via `cargo run --bin
# uniffi-bindgen` (the crate declares a small bin target that calls
# uniffi::uniffi_bindgen_main). There is no reliable standalone
# `uniffi-bindgen` binary to `cargo install`; a global install is the wrong
# approach and was removed deliberately. Here we only verify the prerequisite
# (a working cargo) and, once the core crate exists, that its bindgen bin runs.
check_uniffi() {
  step "UniFFI bindgen (project-driven)"
  load_cargo_env
  if ! have cargo; then
    check_fail "cargo missing; cannot use project-driven uniffi-bindgen"
    return
  fi
  local root
  root="$(repo_root)"
  # The bindgen bin lives inside the photoscore crate as a [[bin]] target,
  # invoked as `cargo run -p photoscore --bin uniffi-bindgen`.
  if [ -f "$root/core/photoscore/src/bin/uniffi-bindgen.rs" ]; then
    if ( cd "$root/core" && cargo run --quiet -p photoscore --bin uniffi-bindgen -- --help >/dev/null 2>&1 ); then
      check_pass "project uniffi-bindgen runs (cargo run -p photoscore --bin uniffi-bindgen)"
    else
      check_fail "photoscore uniffi-bindgen bin present but failed to run"
    fi
  else
    # Core not scaffolded yet: this is expected before the first plan task.
    check_pass "no photoscore bindgen yet (created by the plan's scaffold task; nothing to install globally)"
  fi
}

# --- 0. Homebrew -----------------------------------------------------------
# Preferred macOS package manager. We do not auto-install brew (its installer
# is interactive and changes system paths); we verify it and guide if missing.
check_brew() {
  step "Homebrew"
  if have brew; then
    check_pass "brew $(brew --version | head -1 | awk '{print $2}')"
  else
    warn "Homebrew not found. Install from https://brew.sh, or the script will fall back to direct installers."
    # Not a hard failure: the Rust step falls back to rustup-init without brew.
  fi
}

# --- 4. Optional dev tools (via brew) --------------------------------------
# xcpretty makes `xcodebuild test` output readable; test.sh uses it if present.
ensure_dev_tools() {
  step "Dev tools (optional)"
  if ! have brew; then
    check_pass "skipped (no brew); optional tools not required"
    return
  fi
  if have xcpretty; then
    check_pass "xcpretty present"
  elif [ "$VERIFY_ONLY" -eq 1 ]; then
    warn "xcpretty not installed (optional; nicer test output). Run setup without --verify to add it."
  else
    info "Installing xcpretty via brew..."
    brew list xcpretty >/dev/null 2>&1 || brew install xcpretty
    have xcpretty && check_pass "xcpretty installed" || warn "xcpretty install skipped"
  fi
}

# --- run -------------------------------------------------------------------
if [ "$VERIFY_ONLY" -eq 1 ]; then
  info "Doctor mode: verifying environment (no installs)."
else
  info "Setting up macOS dev environment (idempotent)."
fi
echo

check_brew
echo
check_xcode
echo
ensure_rust
echo
check_uniffi
echo
ensure_dev_tools

verify_summary
