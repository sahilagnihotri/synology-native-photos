#!/usr/bin/env bash
# Build a distributable .dmg installer for the SynologyPhotos macOS app, from
# the command line.
#
# This is the CLI entry point: it builds the Release .app with xcodebuild, then
# hands off to dmg-from-app.sh (the shared packaging source of truth) to lay it
# out and create dist/SynologyPhotos-<version>.dmg. The Xcode "Installer"
# aggregate target calls that same dmg-from-app.sh on the app Xcode builds, so
# CLI and Xcode produce identical installers with no duplicated packaging logic.
#
# Self-healing (per the project rule that a dependent script fixes its own
# prerequisites): rebuilds PhotosCore.xcframework first so the app never links a
# stale core, and regenerates the Xcode project if it is missing.
#
# Usage:
#   scripts/package/dmg.sh            # build the dmg
#   scripts/package/dmg.sh --open     # build, then reveal the dmg in Finder
#
# Signing: builds with the project's Release signing. The team is pinned to the
# Agnihotri AS account (5W67TF3579) and verified by dmg-from-app.sh, never the
# Hexagon work identity also installed here. Not notarized, so on an
# unregistered Mac Gatekeeper needs a right-click -> Open the first time; for
# public distribution switch to a "Developer ID Application" cert (export
# CODE_SIGN_IDENTITY / DEVELOPMENT_TEAM) and add a notarytool step.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$SCRIPT_DIR/../lib/common.sh"

ROOT="$(repo_root)"

# Sign with the Agnihotri AS developer team by default (overridable), matching
# the gate dmg-from-app.sh enforces. Exported so both xcodebuild and the helper
# see the same value.
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-5W67TF3579}"

for arg in "$@"; do
  case "$arg" in
    --open) export DMG_OPEN=1 ;;
    *) warn "ignoring unknown arg: $arg" ;;
  esac
done

APP_NAME="SynologyPhotos"
SCHEME="SynologyPhotos"
PROJECT="$ROOT/app/$APP_NAME.xcodeproj"
BUILD_DD="$ROOT/build/dmg-derived-data"

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

ensure_project
ensure_core
build_app

APP="$BUILD_DD/Build/Products/Release/$APP_NAME.app"
# Hand off to the shared packaging source of truth (staging, /Applications
# alias, signing-team gate, hdiutil), the same script the Xcode Installer
# target calls.
"$SCRIPT_DIR/dmg-from-app.sh" "$APP"

echo
ok "DMG packaging complete."
