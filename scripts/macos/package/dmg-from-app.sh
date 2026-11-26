#!/usr/bin/env bash
# Package an already-built MySynologyPhotos.app into a distributable .dmg.
#
# THE single source of truth for how the macOS installer is laid out, versioned,
# and signing-checked. Both entry points call this on an app they have already
# built, so the packaging logic never drifts into two copies:
#   - scripts/macos/package/dmg.sh  (CLI: builds the Release app, then calls this)
#   - the Xcode "Installer" aggregate target (Xcode builds the app, then a build
#     phase calls this on ${BUILT_PRODUCTS_DIR}/MySynologyPhotos.app)
# Neither path re-invokes xcodebuild from here, so there is no nested-build hang.
#
# Usage: dmg-from-app.sh <path-to-.app> [output-dir]
#   Set DMG_OPEN=1 to reveal the finished dmg in Finder.
#   Set DMG_ALLOW_DIRTY=1 to package despite uncommitted tracked changes.
#   DMG_REPO_ROOT=<dir> uses another git tree (scripts/tests uses a fake one).
# The dmg is named MySynologyPhotos-<app version>[-<short hash>].dmg: the version
# comes from the app's Info.plist, the hash is added when HEAD is not on a tag.
#
# Signing gate: refuses to package unless the app is signed with DEVELOPMENT_TEAM
# (default 5W67TF3579, Agnihotri AS), so a release can never go out signed with
# the Hexagon work identity also installed on this machine, nor unsigned/ad-hoc.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../shared/common.sh
. "$SCRIPT_DIR/../../shared/common.sh"

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5W67TF3579}"
APP_NAME="MySynologyPhotos"

APP="${1:-}"
if [ -z "$APP" ] || [ ! -d "$APP" ]; then
  err "usage: $(basename "$0") <path-to-.app> [output-dir]  (app not found: '${APP:-}')"
  exit 1
fi

ROOT="${DMG_REPO_ROOT:-$(repo_root)}"
OUT_DIR="${2:-$ROOT/build/macos/dist}"
STAGE_DIR="$ROOT/build/macos/dmg-stage"

# Version for the dmg filename and volume name: the built app's own
# CFBundleShortVersionString, so the name always matches the code inside. When
# HEAD is not exactly on a tag the short commit hash is appended, so a build
# from different code never overwrites or impersonates a tagged release.
version() {
  local v sha
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [ -z "$v" ]; then
    err "cannot read CFBundleShortVersionString from $APP/Contents/Info.plist"
    exit 1
  fi
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
     && ! git -C "$ROOT" describe --tags --exact-match HEAD >/dev/null 2>&1; then
    sha="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || true)"
    [ -n "$sha" ] && v="$v-$sha"
  fi
  printf '%s\n' "$v"
}

# Refuse to package a tree with uncommitted changes to tracked files: the dmg
# name carries a commit hash, which would be a lie. DMG_ALLOW_DIRTY=1 overrides.
check_clean_tree() {
  if [ "${DMG_ALLOW_DIRTY:-0}" = "1" ]; then return; fi
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
     && [ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    err "the working tree has uncommitted changes; the dmg would not match any commit. Commit them, or set DMG_ALLOW_DIRTY=1 to package anyway."
    exit 1
  fi
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

check_clean_tree
verify_signing
make_dmg
