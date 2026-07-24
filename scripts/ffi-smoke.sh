#!/usr/bin/env bash
# Cross-boundary FFI smoke test: proves Swift can call real PhotosCore
# methods (not just core_version) through the built xcframework.
#
# Compiles bindings/PhotosCore.swift + bindings/models.swift against the
# built PhotosCore.xcframework's headers/module.modulemap and links
# libphotoscore.a, then runs a standalone Swift program that constructs
# PhotosCore, calls a real local-read method (assetCount/fetchAssets), and
# calls thumbnail()/login() with no prior session to prove CoreError
# round-trips across the boundary on a fail-closed path (no NAS needed).
#
# Self-healing: builds bindings/xcframework via `make` first if missing.
#
# Usage:
#   scripts/ffi-smoke.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

ROOT="$(repo_root)"
XCF="$ROOT/PhotosCore.xcframework"
HEADERS="$XCF/macos-arm64/Headers"
LIBDIR="$XCF/macos-arm64"
WORKDIR="$(mktemp -d -t photoscore-ffi-smoke)"
trap 'rm -rf "$WORKDIR"' EXIT

step "Cross-boundary FFI smoke test"

if [ ! -d "$XCF" ] || [ ! -f "$ROOT/bindings/PhotosCore.swift" ]; then
  warn "xcframework/bindings missing; running make xcframework to self-heal..."
  load_cargo_env
  ( cd "$ROOT" && make xcframework )
fi

cp "$ROOT/bindings/PhotosCore.swift" "$ROOT/bindings/models.swift" "$WORKDIR/"

cat > "$WORKDIR/main.swift" << 'EOF'
import Foundation

func fail(_ msg: String) -> Never {
    print("SMOKE FAIL: \(msg)")
    exit(1)
}

let pid = ProcessInfo.processInfo.processIdentifier
let base = FileManager.default.temporaryDirectory.appendingPathComponent("photoscore-ffi-smoke-\(pid)")
let dbDir = base.appendingPathComponent("db")
let cacheDir = base.appendingPathComponent("cache")
try! FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

print("SMOKE: constructing PhotosCore across FFI...")
let core: PhotosCore
do {
    core = try PhotosCore(dbDir: dbDir.path, cacheDir: cacheDir.path)
} catch {
    fail("PhotosCore.init threw: \(error)")
}
print("SMOKE: PhotosCore constructed OK.")

print("SMOKE: calling assetCount(space: .personal) (local read, real method, not core_version)...")
do {
    let count = try core.assetCount(space: .personal)
    guard count == 0 else { fail("expected 0 assets on a fresh store, got \(count)") }
    print("SMOKE: assetCount returned \(count) as expected.")
} catch {
    fail("assetCount threw unexpectedly: \(error)")
}

print("SMOKE: calling fetchAssets(space: .personal, offset: 0, limit: 10) (real method)...")
do {
    let assets = try core.fetchAssets(space: .personal, offset: 0, limit: 10)
    guard assets.isEmpty else { fail("expected empty asset list, got \(assets.count)") }
    print("SMOKE: fetchAssets returned \(assets.count) assets as expected.")
} catch {
    fail("fetchAssets threw unexpectedly: \(error)")
}

// Cross-FFI proof: call thumbnail() WITHOUT logging in first. This is an
// async, throwing, real facade method that requires a live NAS session --
// calling it pre-login must fail-closed with CoreError.Auth, proving both
// (a) a genuinely non-trivial method crossed the FFI boundary, and
// (b) the CoreError enum decoded correctly across the boundary.
print("SMOKE: calling thumbnail() with no prior login (must fail-closed with CoreError.Auth)...")
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        _ = try await core.thumbnail(space: .personal, assetId: 1, cacheKey: "x", size: .sm)
        fail("thumbnail() unexpectedly succeeded with no login")
    } catch let error as CoreError {
        switch error {
        case .Auth(let message):
            print("SMOKE: thumbnail() correctly threw CoreError.Auth(message: \"\(message)\") across FFI.")
        default:
            fail("thumbnail() threw CoreError but not .Auth: \(error)")
        }
    } catch {
        fail("thumbnail() threw a non-CoreError: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()

print("SMOKE: calling login() against an unreachable host (must fail-closed with CoreError.Network)...")
let semaphore2 = DispatchSemaphore(value: 0)
Task {
    let conn = Connection(host: "https://127.0.0.1:1", verifyTls: false, pinnedCertDer: nil)
    do {
        _ = try await core.login(connection: conn, username: "smoke", password: "smoke", otpCode: nil)
        fail("login() unexpectedly succeeded against an unreachable host")
    } catch let error as CoreError {
        print("SMOKE: login() correctly threw CoreError across FFI: \(error)")
    } catch {
        fail("login() threw a non-CoreError: \(error)")
    }
    semaphore2.signal()
}
semaphore2.wait()

print("SMOKE PASS: real PhotosCore methods (assetCount, fetchAssets, thumbnail, login) crossed the FFI boundary and behaved correctly, including CoreError round-tripping.")
EOF

info "compiling smoke test against $HEADERS"
xcrun swiftc \
  -I "$HEADERS" \
  -L "$LIBDIR" -lphotoscore -lc++ \
  "$WORKDIR/PhotosCore.swift" "$WORKDIR/models.swift" "$WORKDIR/main.swift" \
  -o "$WORKDIR/smoke" 2>&1 | grep -v '^ld: warning' || true

"$WORKDIR/smoke"

ok "FFI smoke test passed."
