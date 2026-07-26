#!/usr/bin/env bash
# Package an already-built MySynologyPhotos.app into a distributable .dmg.
#
# THE single source of truth for how the macOS installer is laid out, versioned,
# and signing-checked. Both entry points call this on an app they have already
# built, so the packaging logic never drifts into two copies:
#   - scripts/package/dmg.sh  (CLI: builds the Release app, then calls this)
#   - the Xcode "Installer" aggregate target (Xcode builds the app, then a build
#     phase calls this on ${BUILT_PRODUCTS_DIR}/MySynologyPhotos.app)
# Neither path re-invokes xcodebuild from here, so there is no nested-build hang.
#
# Usage: dmg-from-app.sh <path-to-.app> [output-dir]
#   Set DMG_OPEN=1 to reveal the finished dmg in Finder.
#
# Signing gate: refuses to package unless the app is signed with DEVELOPMENT_TEAM
# (default 5W67TF3579, Agnihotri AS), so a release can never go out signed with
# the Hexagon work identity also installed on this machine, nor unsigned/ad-hoc.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5W67TF3579}"
APP_NAME="MySynologyPhotos"

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  err "usage: $(basename "$0") <path-to-.app> [output-dir]  (app not found: '${APP:-}')"
  exit 1
fi

ROOT="$(repo_root)"
OUT_DIR="${2:-$ROOT/dist}"
STAGE_DIR="$ROOT/build/dmg-stage"

# Version tag for the dmg filename and volume name: the latest git tag
# (v1.0.1 -> 1.0.1), falling back to the project's MARKETING_VERSION, then 1.0.
version() {
  local v
  v="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')"
  if [ -z "$v" ]; then
    v="$(grep -m1 'MARKETING_VERSION' "$ROOT/app/project.yml" 2>/dev/null | sed -E 's/.*"([0-9.]+)".*/\1/')"
  fi
  [ -n "$v" ] && printf '%s\n' "$v" || printf '%s\n' "1.0"
}

verify_signing() {
  local team
  step "Verifying the app is signed with the expected team"
  team="$(codesign -dvvv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n1)"
  if [ -z "$team" ] || [ "$team" = "not set" ]; then
    err "the app is not signed with a team identifier (got: '${team:-none}'). Refusing to package an unsigned/ad-hoc build."
    exit 1
  fi
  if [ "$team" != "$DEVELOPMENT_TEAM" ]; then
    err "app signed with team '$team', expected '$DEVELOPMENT_TEAM'. Refusing to package with the wrong developer account."
    exit 1
  fi
  ok "signed with team $team"
}

make_dmg() {
  local v dmg volname
  v="$(version)"
  step "Staging the disk image contents"
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  # Copy the app in and drop an /Applications alias beside it: opening the dmg
  # then shows the app + Applications so the user can drag one onto the other.
  cp -R "$APP" "$STAGE_DIR/"
  ln -s /Applications "$STAGE_DIR/Applications"

  mkdir -p "$OUT_DIR"
  volname="$APP_NAME $v"
  dmg="$OUT_DIR/$APP_NAME-$v.dmg"
  rm -f "$dmg"

  step "Creating $dmg"
  # UDZO = zlib-compressed, read-only: the standard shippable dmg format.
  hdiutil create \
    -volname "$volname" \
    -srcfolder "$STAGE_DIR" \
    -ov -format UDZO \
    "$dmg" >/dev/null
  rm -rf "$STAGE_DIR"

  ok "Installer ready: $dmg"
  printf '     size: %s\n' "$(du -h "$dmg" | cut -f1)"
  if [ "${DMG_OPEN:-0}" = "1" ]; then
    open -R "$dmg"
  fi
}

verify_signing
make_dmg
