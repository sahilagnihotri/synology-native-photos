#!/usr/bin/env bash
# Xcode build-phase helper for the PhotosCore framework target.
#
# The PhotosCore framework target compiles bindings/PhotosCore.swift and
# bindings/models.swift against the C headers and static lib that live
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
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
XCF="$ROOT/PhotosCore.xcframework"

if [ -d "$XCF" ] && [ -f "$ROOT/bindings/PhotosCore.swift" ] && [ -f "$ROOT/bindings/models.swift" ]; then
  exit 0
fi

echo "PhotosCore.xcframework missing; building it via 'make xcframework'..."

# shellcheck disable=SC1090
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env" || true

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo not found on PATH (and ~/.cargo/env didn't provide it)." >&2
  echo "Install Rust (see rust-toolchain.toml) before building PhotosCore." >&2
  exit 1
fi

( cd "$ROOT" && make xcframework )
