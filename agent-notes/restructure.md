
---
## restructure worker (context: platform layout W10), 2026-10-16

### Baseline (before step 1)
- cargo test --workspace: 364 passed, 0 failed, 1 ignored.
- xcodebuild unit tests (ad hoc): 498 passed, 0 failed, 0 skipped (xcresult summary).

### Step 1: build outputs under build/
- XCF now build/macos/PhotosCore.xcframework; dmg output build/macos/dist; dmg stage and
  derived data under build/macos/. .gitignore keeps /build only.
- make clean no longer deletes the tracked bindings dir (it ran rm -rf on it before).
- ensure-xcframework.sh now prints "is fresh at <path>" so a build log names the framework used.
- First Swift run after the change: build log shows "PhotosCore.xcframework at
  .../build/macos/PhotosCore.xcframework missing or stale; rebuilding". 498/0/0.
- Old root PhotosCore.xcframework deleted after green; rerun 498/0/0. Rust 364/0/1.
- Staleness script test: 8/8 ok.
- FOUND: the "Ensure PhotosCore.xcframework" phase is skipped on a no-op build (it declares an
  output and no inputs, so Xcode dependency analysis skips it). So a Rust edit does not trigger
  the self heal from Xcode. Fixed in its own commit (basedOnDependencyAnalysis: false).
