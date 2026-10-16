#!/usr/bin/env bash
# Cross check the shared Rust core for Windows from a Mac:
# `cargo xwin check --workspace --all-targets --target x86_64-pc-windows-msvc`.
# Catches Windows only breakage in the core (paths, cfg(windows) code, crates
# that do not build for MSVC) before it reaches the Windows machine. It only
# type checks; it does not link or run anything.
#
# Needs cargo-xwin (which fetches the MSVC CRT and Windows SDK headers on first
# use) and the Windows rust-std for the pinned toolchain. This script never
# installs either: it says what to run and exits with a distinct code.
#
# Usage:
#   scripts/windows/check-core.sh
#
# Exit codes:
#   0  the core type checks for Windows
#   1  the check ran and failed
#   3  cargo-xwin is not installed
#   4  the x86_64-pc-windows-msvc rust-std is not installed for the pinned toolchain

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
. "$SCRIPT_DIR/../shared/common.sh"

ROOT="$(repo_root)"
TARGET="x86_64-pc-windows-msvc"
load_cargo_env
cd "$ROOT"

step "Windows cross check of the core ($TARGET)"

if ! cargo xwin --version >/dev/null 2>&1; then
  err "cargo-xwin is not installed. Install it with:"
  err "    cargo install --locked cargo-xwin"
  err "It also needs clang and lld on PATH (brew install llvm)."
  exit 3
fi

# rustup reads rust-toolchain.toml here, so this lists the pinned toolchain's targets.
if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
  err "the $TARGET standard library is not installed for this repo's toolchain. Install it with:"
  err "    rustup target add $TARGET"
  exit 4
fi

if cargo xwin check --workspace --all-targets --target "$TARGET"; then
  ok "core type checks for $TARGET"
else
  err "core does not build for $TARGET"
  exit 1
fi
