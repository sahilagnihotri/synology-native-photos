#!/usr/bin/env bash
# Xcode build-phase helper for the PhotosCore framework target.
#
# The PhotosCore framework target compiles platforms/macos/Generated/PhotosCore.swift and
# platforms/macos/Generated/models.swift against the C headers and static lib that live
# inside PhotosCore.xcframework (gitignored build output). If that
# xcframework hasn't been built yet, the Swift compile and link steps that
# follow this Run Script phase would fail with confusing header/symbol
# errors. Self-heal instead: run `make xcframework` before Xcode needs it.
#
# Cheap to re-run: if the xcframework and bindings are already present and
# newer than the Rust sources, `make` no-ops via its own dependency chain
# (cargo/make handle their own up-to-date checks).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
XCF="$ROOT/build/macos/PhotosCore.xcframework"
LIB="$XCF/macos-arm64/libphotoscore.a"

# Rebuild when the xcframework or bindings are missing, OR when any build
# input (Rust source, Cargo.toml, Cargo.lock, .udl) is newer than the built
# static lib. Checking existence alone is not enough: a stale lib built from
# old sources will link and run OLD code, which silently hides fixes. The
# logic lives in xcframework-staleness.sh so it can be tested.
needs_build=0
"$SCRIPT_DIR/xcframework-staleness.sh" "$ROOT" >/dev/null || needs_build=1

if [ "$needs_build" -eq 0 ]; then
  # Printed on purpose so a build log shows which xcframework was used.
  echo "PhotosCore.xcframework is fresh at $XCF"
  exit 0
fi

echo "PhotosCore.xcframework at $XCF missing or stale; rebuilding via 'make xcframework'..."

# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH (and ~/.cargo/env didn't provide it)." >&2
  echo "Install Rust (see rust-toolchain.toml) before building PhotosCore." >&2
  exit 1
fi

( cd "$ROOT" && make xcframework )
