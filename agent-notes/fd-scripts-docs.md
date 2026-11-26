# fd-scripts-docs notes

### R6-7: FIXED
- commit: d2758a0
- test: scripts/tests/test-setup-args.sh (6 cases, stub brew/rustup/rustup-init/curl/cargo/rustc/xcodebuild/swift record any call)
- failed before the fix: with the old setup.sh, `--bogus`: "wanted exit 2 and no tool calls, got exit 1, calls: brew --version;xcodebuild -version;" (6 of 6 cases failed)
- passes after: bash scripts/tests/test-setup-args.sh, "all passed", exit 0
- changed tests: none
- left open: `--verify` still compiles the bindgen bin via `cargo run`, and check_uniffi passes when the bindgen source is absent (second half of the finding, not in the queue item). Not changed.

### R6-6: FIXED
- commit: ad4d57d
- test: scripts/tests/test-entrypoints.sh (test.sh bogus flag exits 2; test-app.sh with no .xcodeproj exits 1). Added APP_DIR_OVERRIDE to test-app.sh as the seam.
- failed before the fix: "FAIL test.sh rejects a mistyped flag with exit 2: wanted exit 2, got 0" and "FAIL test-app.sh fails when there is no Xcode project: wanted exit 1, got 0"
- passes after: all passed, exit 0
- changed tests: none

### TODO item "ci.sh swift stage FAIL path not falsified" and R6-5: FIXED (one commit, same two files)
- commit: 88a6c1a
- test: scripts/tests/test-ci.sh gains 3 core cases (zero tests, no lockfile, passed count) and 5 swift cases driven by CI_TEST_APP and CI_BUNDLE_DIR overrides plus a fake xcrun on PATH (Mac only).
- falsified with mutants of ci.sh: ignoring the xcodebuild exit code -> "FAIL swift: nonzero xcodebuild exit with clean counts fails"; dropping --locked -> "FAIL tree without a lockfile fails the gate"; dropping the zero test check -> "FAIL tree with zero tests fails the test stage"; ignoring skipped/failed counts -> "FAIL swift: skipped test fails".
- passes after: all passed, exit 0 (15 cases)
- left open: the real xcodebuild path of the swift stage is still not run by a test (stubbed seam only).

### R6-8: FIXED
- commit: 02b7301
- test: scripts/tests/test-xcframework-staleness.sh, 6 new cases (uniffi.toml, rust-toolchain.toml, Makefile, .cargo/config.toml, deleted source, target dir ignored). A deleted source is detected by a directory under core/ being newer than the lib (no manifest needed).
- failed before the fix: old checker via CHECK_OVERRIDE: 5 FAIL (uniffi.toml, rust-toolchain.toml, Makefile, .cargo/config.toml, deleted source all read fresh)
- passes after: all passed (14 cases)
- left open: tracked bindings are still not compared against the lib.

### R6-1: FIXED
- commit: 2073e2c (+ lint follow-up)
- test: scripts/tests/test-dmg-naming.sh with a fake git repo, fake .app (plist 2.3, tag v1.0.2), stub codesign and hdiutil. New env: DMG_REPO_ROOT (test seam), DMG_ALLOW_DIRTY=1 (override).
- failed before the fix: tag-based mutant: "FAIL tagged HEAD: name uses the app version, not the tag: files=MySynologyPhotos-1.0.2.dmg"; without the clean check: "FAIL dirty tree is refused"
- passes after: all passed (4 cases)
- left open: dirty check ignores untracked files on purpose (old layout leftovers are untracked, see R6-2).

### R6-9: NEEDS RULING
- Confirmed by grep over src, tests, examples, build.rs at the current tree (not by cargo check, see below): unused direct dependencies: models: serde; persistence: thiserror, tracing; photoscore: thiserror, tracing; sync-engine: thiserror; synology-api: thiserror, webpki-roots. Used, keep: models thiserror (`thiserror::Error` derive at lib.rs:495), sync-engine tracing (crawl.rs:148).
- Why not removed: every removal changes Cargo.lock (it lists each package's dependencies), which I may not touch. I also did not run cargo check in a copied tree (machine load above 70).
- Option A: orchestrator removes the 8 lines, runs `cargo check --workspace --all-targets`, commits manifests plus Cargo.lock together. Option B: leave them and add cargo-machete to the gate.
- Note: webpki-roots direct dependency does not change the trust store (reaches reqwest anyway).

### R6-11: FIXED (files I own)
- commit: 488cf68, plus the HANDOVER.md line in a following commit
- CLAUDE.md (GRDB -> rusqlite, core decision resolved, heading no longer "to be confirmed"), documentation/platforms/macos.md (staleness inputs, dmg naming), scripts/README.md, documentation/HANDOVER.md.
- NEEDS RULING (not my files): platforms/macos/project.yml comment above CODE_SIGN_STYLE says DEVELOPMENT_TEAM is left unset while the next line sets it; Fixed.md records bundle ids se.agnihotri.synologyphotos.* but the project uses se.agnihotri.mysynologyphotos, ...MySynologyPhotosTests, ...PhotosCore.

### R6-3: NEEDS RULING
Fixed.md holds 32 commit hashes that no longer exist in the repo (`git cat-file -e` fails). Fixed.md records no commit subjects, only prose, so no same-subject match in `git log --all` can be established mechanically (331 commits in the log). Likely cause: history was rewritten. Options: strip the dead hashes, or re-map by hand from the entry text. List (Fixed.md line, dead hash):
- 425 eeabc83
- 426 9f0cd36
- 427 f78e511
- 428 3630c70
- 428 c0fcbeb
- 429 8f6d973
- 430 bc48af8
- 431 00b3f49
- 432 d96686d
- 433 3b7b41a
- 433 7249e6e
- 433 7cac4ef
- 433 7e6683e
- 433 965aa39
- 435 10fdeac
- 436 c0fcbeb
- 436 f505790
- 444 1379dd1
- 444 28d04ad
- 444 4cd187b
- 444 5777cc4
- 444 68dfa29
- 444 9831ef8
- 444 d478428
- 444 df0e635
- 445 38fecb6
- 445 54856ae
- 445 8a628e8
- 445 93d194f
- 445 b0458c3
- 445 cfc9360
- 445 fb0eeb6
