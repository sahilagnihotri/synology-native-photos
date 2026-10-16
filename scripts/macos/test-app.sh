#!/usr/bin/env bash
# Run the macOS app unit tests (MySynologyPhotosTests) with xcodebuild.
#
# Unit tests only: the UI test target drives the app through System Events,
# which raises an automation permission prompt on every run, so it is never
# run from here. Test timeouts are on, so a hung test fails instead of
# stalling the run.
#
# Usage:
#   scripts/macos/test-app.sh
#   ADHOC_SIGN=1 scripts/macos/test-app.sh    # sign ad hoc (no keychain access),
#                                             # for shells such as a sandboxed agent
#   RESULT_BUNDLE=<path> scripts/macos/test-app.sh   # keep the .xcresult there

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../shared/common.sh
. "$SCRIPT_DIR/../shared/common.sh"

ROOT="$(repo_root)"
APP_DIR="$ROOT/platforms/macos"

step "Swift / macOS app tests"
if ! ls "$APP_DIR"/*.xcodeproj >/dev/null 2>&1; then
  warn "no Xcode project at platforms/macos/; skipping app tests."
  exit 0
fi

proj="$(ls -d "$APP_DIR"/*.xcodeproj | head -n1)"
scheme="$(basename "$proj" .xcodeproj)"
extra_args=()
if [ "${ADHOC_SIGN:-0}" = "1" ]; then
  extra_args+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
fi
if [ -n "${RESULT_BUNDLE:-}" ]; then
  # xcodebuild refuses to overwrite an existing bundle.
  rm -rf "$RESULT_BUNDLE"
  extra_args+=(-resultBundlePath "$RESULT_BUNDLE")
fi

xcodebuild test \
  -project "$proj" \
  -scheme "$scheme" \
  -destination 'platform=macOS' \
  -only-testing:"${scheme}Tests" \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 30 \
  ${extra_args[@]+"${extra_args[@]}"} \
  | { have xcpretty && xcpretty || cat; }
ok "app tests done"
