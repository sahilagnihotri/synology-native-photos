#!/usr/bin/env bash
# Tests the naming and clean-tree rules of scripts/macos/package/dmg-from-app.sh
# against a fake git repo and a fake .app under $TMPDIR. codesign and hdiutil
# are stubs earlier on PATH, so nothing is signed and no disk image is built.
# DMG_SCRIPT lets a mutated copy be checked against these cases.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
DMG="${DMG_SCRIPT:-$REPO/scripts/macos/package/dmg-from-app.sh}"
BASE="$(mktemp -d "${TMPDIR:-/tmp}/dmg-name.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT
mkdir -p "$BASE/bin"
printf '#!/bin/sh\necho "TeamIdentifier=5W67TF3579" >&2\n' > "$BASE/bin/codesign"
# The stub hdiutil creates the file named by its last argument.
printf '#!/bin/sh\nfor a; do f="$a"; done\n: > "$f"\n' > "$BASE/bin/hdiutil"
chmod +x "$BASE/bin/codesign" "$BASE/bin/hdiutil"
export PATH="$BASE/bin:$PATH"

# fake_repo <name>: a git repo with one commit tagged v1.0.2, plus a fake app
# whose plist says 2.3. The app lives outside the repo so it never makes it dirty.
fake_repo() {
  local r="$BASE/$1"
  mkdir -p "$r" "$BASE/$1-app/MySynologyPhotos.app/Contents"
  cat > "$BASE/$1-app/MySynologyPhotos.app/Contents/Info.plist" <<'X'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>2.3</string></dict></plist>
X
  ( cd "$r" && git init -q && echo a > f && git add f \
    && git -c user.name=t -c user.email=t@example.com commit -q -m one && git tag v1.0.2 )
  echo "$r"
}
commit_more() { ( cd "$1" && echo b >> f && git -c user.name=t -c user.email=t@example.com commit -q -am two ); }

fails=0
# run_dmg <repo> [env assignments...]: prints the output, sets rc
run_dmg() {
  local r="$1"; shift
  env DMG_REPO_ROOT="$r" "$@" bash "$DMG" "$BASE/$(basename "$r")-app/MySynologyPhotos.app" "$r/out" 2>&1
}
check() {  # check <name> <condition result 0|1> <detail>
  if [ "$2" -eq 0 ]; then echo "ok   $1"; else echo "FAIL $1: $3"; fails=$((fails + 1)); fi
}

r="$(fake_repo tagged)"
out="$(run_dmg "$r")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$r/out/MySynologyPhotos-2.3.dmg" ]; st=$?; check "tagged HEAD: name uses the app version, not the tag" $st "rc=$rc files=$(ls "$r/out" 2>/dev/null)"

r="$(fake_repo ahead)"; commit_more "$r"
short="$(git -C "$r" rev-parse --short HEAD)"
out="$(run_dmg "$r")"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$r/out/MySynologyPhotos-2.3-$short.dmg" ]; st=$?; check "HEAD past the tag: short hash is in the name" $st "rc=$rc files=$(ls "$r/out" 2>/dev/null)"

r="$(fake_repo dirty)"; echo changed >> "$r/f"
out="$(run_dmg "$r")"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "uncommitted" && [ ! -d "$r/out" ]; st=$?; check "dirty tree is refused and nothing is built" $st "rc=$rc"

r="$(fake_repo dirtyok)"; echo changed >> "$r/f"
out="$(run_dmg "$r" DMG_ALLOW_DIRTY=1)"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$r/out/MySynologyPhotos-2.3.dmg" ]; st=$?; check "DMG_ALLOW_DIRTY=1 overrides the refusal" $st "rc=$rc"

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
