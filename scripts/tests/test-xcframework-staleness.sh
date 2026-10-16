#!/usr/bin/env bash
# Tests scripts/xcodegen/xcframework-staleness.sh against fake trees under
# $TMPDIR. Never builds anything and never touches the real repo.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/../xcodegen/xcframework-staleness.sh"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/xcf-stale.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

fails=0
n=0

# Fresh tree: everything old (2020), lib newer (2021).
mk() {
  local d="$BASE/t$n"
  mkdir -p "$d/build/macos/PhotosCore.xcframework/macos-arm64" "$d/platforms/macos/Generated" "$d/core/a/src" "$d/core/photoscore/src"
  touch "$d/platforms/macos/Generated/PhotosCore.swift" "$d/platforms/macos/Generated/models.swift" \
        "$d/core/a/src/lib.rs" "$d/core/a/Cargo.toml" "$d/core/photoscore/src/x.udl" \
        "$d/Cargo.toml" "$d/Cargo.lock"
  find "$d" -type f -exec touch -t 202001010000 {} +
  touch -t 202101010000 "$d/build/macos/PhotosCore.xcframework/macos-arm64/libphotoscore.a"
  echo "$d"
}

# expect <name> <fresh|stale> <dir>
expect() {
  local out
  out="$("$CHECK" "$3")"
  if [ "$out" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: wanted $2, got $out"; fails=$((fails+1)); fi
}

n=1; d="$(mk)"; expect "all older than lib is fresh" fresh "$d"
n=2; d="$(mk)"; touch "$d/core/a/src/lib.rs"; expect "newer .rs is stale" stale "$d"
n=3; d="$(mk)"; touch "$d/core/a/Cargo.toml"; expect "newer crate Cargo.toml is stale" stale "$d"
n=4; d="$(mk)"; touch "$d/Cargo.toml"; expect "newer root Cargo.toml is stale" stale "$d"
n=5; d="$(mk)"; touch "$d/Cargo.lock"; expect "newer Cargo.lock is stale" stale "$d"
n=6; d="$(mk)"; touch "$d/core/photoscore/src/x.udl"; expect "newer .udl is stale" stale "$d"
n=7; d="$(mk)"; rm "$d/build/macos/PhotosCore.xcframework/macos-arm64/libphotoscore.a"; expect "missing lib is stale" stale "$d"
n=8; d="$(mk)"; rm "$d/platforms/macos/Generated/models.swift"; expect "missing bindings is stale" stale "$d"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
