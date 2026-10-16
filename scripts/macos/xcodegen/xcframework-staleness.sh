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
# Cargo.toml (root or crate), Cargo.lock, or a UniFFI .udl file.

set -euo pipefail
ROOT="${1:?usage: xcframework-staleness.sh <repo-root>}"
LIB="$ROOT/build/macos/PhotosCore.xcframework/macos-arm64/libphotoscore.a"

stale() { echo stale; exit 10; }

if [ ! -f "$LIB" ] || [ ! -f "$ROOT/platforms/macos/Generated/PhotosCore.swift" ] || [ ! -f "$ROOT/platforms/macos/Generated/models.swift" ]; then
  stale
fi

# Anything under core/ that feeds the build.
if [ -d "$ROOT/core" ] && [ -n "$(find "$ROOT/core" \( -name '*.rs' -o -name 'Cargo.toml' -o -name '*.udl' \) -newer "$LIB" -print -quit 2>/dev/null)" ]; then
  stale
fi

# Workspace manifest and lockfile at the root.
for f in "$ROOT/Cargo.toml" "$ROOT/Cargo.lock"; do
  if [ -f "$f" ] && [ "$f" -nt "$LIB" ]; then
    stale
  fi
done

echo fresh
