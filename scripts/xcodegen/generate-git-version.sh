#!/usr/bin/env bash
# Xcode build-phase helper: write the short git commit SHA into a generated
# Swift source the About window reads (GitVersion.shortSHA).
#
# The generated file is gitignored build output, regenerated on every build.
# It lives OUTSIDE the globbed SynologyPhotos source dir so it is a single
# explicit file reference in the project, never a duplicate of a directory
# glob entry.
#
# Robustness rules this script follows on purpose:
#   * It never fails the build. `set -e` is deliberately NOT used, so a
#     missing git, a non-repo checkout, or any git error falls back to
#     "unknown" instead of aborting the compile.
#   * Write-if-changed: the file is only rewritten when the SHA actually
#     changes, so an unchanged commit does not touch the file mtime and does
#     not force Xcode to recompile it every build.
#
# Usage:
#   generate-git-version.sh [output_path]
# When run from the Xcode build phase the output path is passed explicitly
# ("${SRCROOT}/Generated/GitVersion.swift"). When run by hand with no arg it
# defaults to app/Generated/GitVersion.swift under the repo root.

set -uo pipefail

OUT="${1:-}"
if [ -z "$OUT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
  OUT="$ROOT/app/Generated/GitVersion.swift"
fi

SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
[ -z "$SHA" ] && SHA="unknown"

CONTENT="// Generated at build time by scripts/xcodegen/generate-git-version.sh.
// Do not edit and do not commit (see .gitignore). Holds the short git commit
// SHA the running executable was built from, surfaced in the About window.
enum GitVersion {
    static let shortSHA = \"$SHA\"
}
"

mkdir -p "$(dirname "$OUT")"

# Only write when the content changed, to keep the file mtime stable across
# rebuilds of the same commit and avoid a needless recompile.
if [ -f "$OUT" ] && [ "$(cat "$OUT")" = "$CONTENT" ]; then
  exit 0
fi

printf '%s' "$CONTENT" > "$OUT"
echo "generate-git-version.sh: wrote GitVersion.shortSHA = $SHA -> $OUT"
