#!/usr/bin/env bash
# Build a distributable .dmg installer for the SynologyPhotos macOS app.
#
# Produces dist/SynologyPhotos-<version>.dmg containing the Release .app next to
# an /Applications alias, so the DMG opens to the familiar "drag the app onto
# Applications" installer layout. Uses only hdiutil (ships with macOS), no extra
# tooling to install.
#
# Self-healing (per the project rule that a dependent script fixes its own
# prerequisites): rebuilds PhotosCore.xcframework first so the app never links a
# stale core, and regenerates the Xcode project if it is missing.
#
# Usage:
#   scripts/package/dmg.sh            # build the dmg
#   scripts/package/dmg.sh --open     # build, then open the dmg in Finder
#
# Signing: the app is built with the project's existing Release signing (Apple
# Development, team 5W67TF3579). That is fine for running on the build machine
# and other Macs registered to that developer account. It is NOT notarized, so
# on an unregistered Mac Gatekeeper will require a right-click -> Open the first
# time. For public distribution, switch CODE_SIGN_IDENTITY to a "Developer ID
# Application" cert and add a notarytool step (see the TODO note); this script
# honours CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM env overrides so that path can
# reuse it.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

ROOT="$(repo_root)"
OPEN_AFTER=0
for arg in "$@"; do
  case "$arg" in
    --open) OPEN_AFTER=1 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

# Sign with the Agnihotri AS developer team by default. This machine also has a
# Hexagon (work) Apple Development identity installed, but it belongs to a
# different team and so is never eligible once this team is pinned, the release
# is always signed under the personal/AS account, never the work one. Override
# by exporting DEVELOPMENT_TEAM (e.g. for a Developer ID + notarize build).
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5W67TF3579}"

APP_NAME="SynologyPhotos"
SCHEME="SynologyPhotos"
PROJECT="$ROOT/app/$APP_NAME.xcodeproj"
BUILD_DD="$ROOT/build/dmg-derived-data"
DIST_DIR="$ROOT/dist"
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

ensure_project() {
  if [ ! -d "$PROJECT" ]; then
    step "Xcode project missing; generating with xcodegen"
    if ! have xcodegen; then
      err "xcodegen not found. Install it (brew install xcodegen) or run scripts/setup/macos.sh."
      exit 1
    fi
    ( cd "$ROOT/app" && xcodegen generate )
  fi
}

ensure_core() {
  step "Building PhotosCore.xcframework (so the app links the current core)"
  ( cd "$ROOT" && make xcframework )
  ok "xcframework ready"
}

build_app() {
  step "Building the Release app"
  rm -rf "$BUILD_DD"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$BUILD_DD" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    ${CODE_SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"} \
    | { have xcpretty && xcpretty || cat; }
  ok "Release build done"
}

verify_signing() {
  local app team
  app="$BUILD_DD/Build/Products/Release/$APP_NAME.app"
  step "Verifying the app is signed with the expected team"
  team="$(codesign -dvvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -n1)"
  if [ -z "$team" ] || [ "$team" = "not set" ]; then
    err "the built app is not signed with a team identifier (got: '${team:-none}'). Refusing to package an unsigned/ad-hoc build."
    exit 1
  fi
  if [ "$team" != "$DEVELOPMENT_TEAM" ]; then
    err "app signed with team '$team', expected '$DEVELOPMENT_TEAM'. Refusing to package with the wrong developer account."
    exit 1
  fi
  ok "signed with team $team"
}

make_dmg() {
  local version app dmg volname
  version="$(version)"
  app="$BUILD_DD/Build/Products/Release/$APP_NAME.app"
  if [ ! -d "$app" ]; then
    err "built app not found at: $app"
    exit 1
  fi

  step "Staging the disk image contents"
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  # Copy the app in and drop an /Applications alias beside it: opening the dmg
  # then shows the app + Applications so the user can drag one onto the other.
  cp -R "$app" "$STAGE_DIR/"
  ln -s /Applications "$STAGE_DIR/Applications"

  mkdir -p "$DIST_DIR"
  volname="$APP_NAME $version"
  dmg="$DIST_DIR/$APP_NAME-$version.dmg"
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
  if [ "$OPEN_AFTER" -eq 1 ]; then
    open -R "$dmg"
  fi
}

ensure_project
ensure_core
build_app
verify_signing
make_dmg
echo
ok "DMG packaging complete."
