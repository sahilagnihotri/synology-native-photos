#!/usr/bin/env bash
# Decide whether PhotosCore.xcframework needs rebuilding.
#
# Usage: xcframework-staleness.sh <repo-root>
# Prints "stale" and exits 10 when a rebuild is needed, prints "fresh" and
# exits 0 otherwise. Kept separate from ensure-xcframework.sh so it can be
# tested against a fake tree without running a real build.
#
# Stale when the static lib or generated bindings are missing, or when any
# input that changes the built lib is newer than the lib: Rust sources, any
# Cargo.toml (root or crate), Cargo.lock, a UniFFI .udl or uniffi.toml file,
# rust-toolchain.toml, .cargo/config*, or the Makefile (it holds the deployment
# target). A directory under core/ newer than the lib also counts as stale: a
# deleted, added or renamed source file changes its directory mtime.

set -euo pipefail
ROOT="${1:?usage: xcframework-staleness.sh <repo-root>}"
LIB="$ROOT/build/macos/PhotosCore.xcframework/macos-arm64/libphotoscore.a"

stale() { echo stale; exit 10; }

if [ ! -f "$LIB" ] || [ ! -f "$ROOT/platforms/macos/Generated/PhotosCore.swift" ] || [ ! -f "$ROOT/platforms/macos/Generated/models.swift" ]; then
  stale
fi

# Anything under core/ that feeds the build.
if [ -d "$ROOT/core" ] && [ -n "$(find "$ROOT/core" \( -name '*.rs' -o -name 'Cargo.toml' -o -name '*.udl' -o -name 'uniffi.toml' \) -newer "$LIB" -print -quit 2>/dev/null)" ]; then
  stale
fi

# A removed, added or renamed file touches its directory, not the lib's inputs.
if [ -d "$ROOT/core" ] && [ -n "$(find "$ROOT/core" -name target -prune -o -type d -newer "$LIB" -print -quit 2>/dev/null)" ]; then
  stale
fi

# Workspace manifest, lockfile, toolchain pin, cargo config and Makefile at the root.
for f in "$ROOT/Cargo.toml" "$ROOT/Cargo.lock" "$ROOT/rust-toolchain.toml" "$ROOT/Makefile" "$ROOT"/.cargo/config "$ROOT"/.cargo/config.toml; do
  if [ -f "$f" ] && [ "$f" -nt "$LIB" ]; then
    stale
  fi
done

echo fresh
