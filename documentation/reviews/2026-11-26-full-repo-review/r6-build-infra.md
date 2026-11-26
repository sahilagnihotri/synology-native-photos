# r6-build-infra review notes

## r6-build-infra, 2026-11-26 (HEAD d34b066)

Scope: scripts (shared, macos, ci, tests), Makefile, Cargo manifests and lock, project.yml vs committed xcodeproj, .gitignore, history secret scan, docs drift. Windows scripts and ci.yml triggers not reviewed by instruction. No secret value is repeated here.

### R6-1: dmg is named after the latest git tag, which can disagree with the app version and the code inside
- severity: medium
- confidence: high
- location: scripts/macos/package/dmg-from-app.sh:36
- defect: `version()` uses `git describe --tags --abbrev=0` for the file and volume name. The app's own version comes from `MARKETING_VERSION` (project.yml, "1.0", build "1"). The script never checks that the two agree, that HEAD is the tagged commit, or that the tree is clean.
- failure scenario: at HEAD, `git describe --tags` prints `v1.0.2-64-g51bdfcc` and `git rev-list v1.0.2..HEAD --count` prints 64. `make dmg` writes `MySynologyPhotos-1.0.2.dmg` containing an app whose About window and Info.plist say 1.0 (1), built from a tree 64 commits (and any uncommitted edits) past the tag. A later build from different code overwrites the same file name.
- evidence: EXECUTED `git describe --tags`, `git rev-list v1.0.2..HEAD --count` (64); `grep MARKETING_VERSION platforms/macos/project.yml` (1.0); version() read-only.
- suggested fix: take the version from the built app (`PlistBuddy -c 'Print CFBundleShortVersionString'` on `$APP/Contents/Info.plist`), append the short SHA, and refuse (or add `-dirty`) when `git status --porcelain` is not empty.
- suggested test: a script test with a fake app bundle whose plist says 2.3 and a tag saying 1.0.2: the produced name must contain 2.3.

### R6-2: `.gitignore` does not cover the old-layout leftovers, and the global rule is `git add -A`
- severity: medium
- confidence: high
- location: .gitignore (missing entries for `/app/`, `/PhotosCore.xcframework/`, `/dist/`)
- defect: `git check-ignore -v dist app PhotosCore.xcframework` prints nothing (exit 1). `git status` lists all three as untracked. The standing workflow commits with `git add -A && git commit && git push`.
- failure scenario: the next periodic commit adds `PhotosCore.xcframework/` (52 MB of static library), `dist/MySynologyPhotos-1.0.1.dmg` (6.2 MB signed app) and the stale `app/` sources to a PUBLIC repo. History cannot be cleaned without another force push.
- evidence: EXECUTED `git check-ignore -v ...` (rc=1, no output), `git status --short` (`?? PhotosCore.xcframework/`, `?? app/`, `?? dist/`), `du -sh` (6.2M, 44K, 52M).
- suggested fix: add `/app/`, `/PhotosCore.xcframework/`, `/dist/`, and `*.dmg`, `*.xcframework/` to .gitignore now, delete the directories later (HOUSEKEEPING-1 only records the leftovers, not this hazard).
- suggested test: `git check-ignore dist/x.dmg app/x PhotosCore.xcframework/x` exits 0 (add to a scripts/tests hygiene test).

### R6-3: 32 commit hashes in Fixed.md no longer exist
- severity: low
- confidence: high
- location: Fixed.md:400-412 region (first dead one `eeabc83` line 400)
- defect: Fixed.md says all commit authors were rewritten and force pushed. Entries written before that cite the old hashes. `git cat-file -e <hash>^{commit}` fails for 32 of the 128 hash-like tokens (96 resolve). TODO.md, tasks.md and HANDOVER.md have no dead ones.
- failure scenario: someone follows `(3630c70)` or `(00b3f49)` from Fixed.md to find the fix and `git show` says unknown revision. The leaf-cert pinning, X-SYNO-TOKEN, unit_id and login hardening fixes are among them.
- evidence: EXECUTED a python loop over Fixed.md tokens with `git cat-file -e` (Fixed.md ok 96 missing 32). Also Fixed.md:399 states the rewritten author email in a tracked file (already in commit metadata, so only a note).
- suggested fix: map old to new hashes by subject (`git log --format='%h %s'`) and rewrite them, or add a header saying hashes before the rewrite are void.
- suggested test: a script test that extracts backticked hashes from Fixed.md and fails on any `git cat-file -e` miss.

### R6-4: the TODO.md claim about ffi-smoke is wrong, and the suggested fix would break the success path
- severity: low
- confidence: high
- location: scripts/macos/ffi-smoke.sh:127-131, TODO.md ("a `|| true` hides the compile error, so it reports success while testing nothing")
- defect: with `set -euo pipefail`, a failed compile leaves no `$WORKDIR/smoke`, so `"$WORKDIR/smoke"` dies with "No such file" and the script exits non-zero. It does not report success (the compile error text is also printed, only `ld: warning` lines are filtered). Separately, removing `|| true` as TODO proposes makes a SUCCESSFUL compile fail: `grep -v '^ld: warning'` exits 1 when swiftc prints nothing, and pipefail turns that into a pipeline failure.
- failure scenario: the fixer drops `|| true`, the smoke test now aborts before running on every clean compile.
- evidence: EXECUTED a model of the lines: `echo "compile error" | grep -v ... || true; "$W/smoke"` printed "No such file", rc=1 (never printed success). Pipeline behaviour of `grep -v` with empty input is standard (rc 1).
- suggested fix: capture swiftc output to a variable, check swiftc's own status, print the output with the warnings filtered, then run smoke. Correct TODO.md.
- suggested test: run the script against a tree where the Swift call is wrong, expect non-zero and the compiler error in the output; against a good one, expect SMOKE PASS.

### R6-5: the core gate does not use `--locked` and has no minimum test count
- severity: low
- confidence: medium
- location: scripts/ci/ci.sh:94-96, scripts/shared/test-core.sh:46
- defect: `cargo clippy` and `cargo test` run without `--locked`. A manifest edit without a lock update lets cargo rewrite Cargo.lock inside the gate run and still print PASS, leaving a dirty tree and, offline-first, a resolution nobody reviewed. The stage also passes with zero tests (a crate whose tests were deleted or cfg'd out).
- failure scenario: someone bumps a version in a crate Cargo.toml, runs `ci.sh core`, gets CI PASS, commits the manifest only. A clean CI checkout resolves differently. `cargo metadata --locked --offline` is clean at HEAD (rc 0), so this is a gap, not a live break.
- evidence: READ-ONLY on ci.sh; EXECUTED `cargo metadata --locked --offline` rc=0.
- suggested fix: add `--locked` to the fmt/clippy/test invocations and fail the test stage when `passed` falls below a floor read from a checked in file.
- suggested test: in test-ci.sh a fake tree whose Cargo.lock is stale must give `FAIL`.

### R6-6: test entry points fail open on a missing project or a mistyped flag
- severity: low
- confidence: high
- location: scripts/macos/test-app.sh:22-25, scripts/test.sh:25-30
- defect: when no `*.xcodeproj` exists, test-app.sh warns and `exit 0`, so `scripts/test.sh macos` ends with "Test run complete." (ci.sh catches it only because it also demands an xcresult). test.sh warns and ignores unknown arguments, so `scripts/test.sh --include-integraton` runs the normal suite and exits 0 without the integration tests.
- failure scenario: the project is deleted or moved: the green "Test run complete" hides that zero Swift tests ran.
- evidence: READ-ONLY.
- suggested fix: exit non-zero when the project is missing, exit 2 on an unknown argument.
- suggested test: run test.sh with a bogus flag, expect rc 2.

### R6-7: setup.sh installs software on anything other than `--verify` as the first argument
- severity: low
- confidence: high
- location: scripts/macos/setup.sh:20
- defect: `[ "${1:-}" = "--verify" ] && VERIFY_ONLY=1`. `setup.sh --check`, `-v`, `--verfiy` or `--verify` in second position fall into install mode: `brew install rustup`, `rustup default stable`, `curl ... | sh`, `rustup target add`, `brew install xcpretty`. Also `--verify` still compiles the photoscore bindgen binary via `cargo run` (heavy, and writes `target/`), and `check_uniffi` reports PASS when the bindgen source file is missing.
- failure scenario: a typo in doctor mode silently changes the machine.
- evidence: READ-ONLY (not run, per brief).
- suggested fix: reject unknown arguments with exit 2; use `cargo metadata`/file existence for the verify check.
- suggested test: `setup.sh --bogus` exits 2 without touching anything.

### R6-8: xcframework staleness ignores several inputs
- severity: low
- confidence: high
- location: scripts/macos/xcodegen/xcframework-staleness.sh:25-33
- defect: only `*.rs`, any `Cargo.toml`, `*.udl` under core/ and the root Cargo.toml/Cargo.lock are compared. A `uniffi.toml`, `rust-toolchain.toml`, `Makefile` (including `MACOSX_DEPLOYMENT_TARGET`) or a deleted source file all read as fresh. It also never compares the tracked bindings against the lib.
- failure scenario: the deployment target in the Makefile is raised, or the toolchain pinned in rust-toolchain.toml changes: Xcode keeps linking the old static library until a Rust file is touched. `core/photoscore/uniffi.toml` exists in the tree.
- evidence: EXECUTED the checker on a fake tree in `$TMPDIR` after `touch` of each file: `core/a/uniffi.toml newer -> fresh`, `rust-toolchain.toml newer -> fresh`, `Makefile newer -> fresh`, `deleted lib.rs -> fresh`. `scripts/tests/test-xcframework-staleness.sh` passes 8 of 8 and covers none of these. (No `.udl` file exists in the repo, proc-macro mode.)
- suggested fix: add `uniffi.toml`, `rust-toolchain.toml`, the Makefile and `.cargo/config*` to the compared set; treat a deleted source as stale by recording a hash of the sorted file list.
- suggested test: one more fake-tree case per input.

### R6-9: declared dependencies that no source file uses
- severity: low
- confidence: medium
- location: core/models/Cargo.toml (serde), core/persistence/Cargo.toml (thiserror, tracing), core/photoscore/Cargo.toml (thiserror, tracing), core/sync-engine/Cargo.toml (thiserror), core/synology-api/Cargo.toml (thiserror, webpki-roots)
- defect: a word search over each crate's `src/` and `tests/` finds no use. `webpki-roots` is only reached through reqwest (`cargo tree -i webpki-roots` shows reqwest and synology-api), so the direct dependency does not change the trust store. Unused crates grow build time and the audit surface.
- evidence: EXECUTED a grep loop (`grep -rlw` per crate), `cargo tree -i webpki-roots --offline`. Not confirmed by removing them (read-only), so confidence medium.
- suggested fix: install `cargo-machete` or `cargo udeps` and run it in the gate, then drop what it confirms.
- suggested test: the gate stage itself.

### R6-10: no advisory check, and the bundled SQLite is old
- severity: low
- confidence: medium
- location: Cargo.lock (libsqlite3-sys 0.30.1 / rusqlite 0.32.1)
- defect: the bundled SQLite is 3.46.0 (read from `sqlite3.c` of the vendored crate). Newer SQLite releases fixed several memory safety bugs. cargo-audit and cargo-deny are not installed and the gate has no advisory step, so nothing flags this. rustls 0.23.42, rustls-webpki 0.103.13, ring 0.17.14, reqwest 0.12.28, h2 0.4.15, hyper 1.11.0 look current; I could not check them against the RustSec database offline.
- failure scenario: only reachable through SQL the app itself builds against its own database file, so exploitability is low. A crafted DB file placed in the app support directory is the realistic vector.
- evidence: EXECUTED `grep -o 'define SQLITE_VERSION ...' sqlite3.c` (3.46.0), `grep` of Cargo.lock versions.
- suggested fix: bump rusqlite to a release that bundles a current SQLite and add `cargo audit` (manual, not in the offline gate).
- suggested test: n/a (a lock check).

### R6-11: docs drift
- severity: low
- confidence: high
- location: CLAUDE.md:30-31, platforms/macos/project.yml (comment above `CODE_SIGN_STYLE` in the app target), documentation/platforms/macos.md Build section, scripts/README.md (bindgen "once scaffolded"), Fixed.md bundle id entry
- defect: CLAUDE.md still says the local index is GRDB and the core language is "decision pending": the code is rusqlite in a Rust core exposed by UniFFI. The project.yml comment says DEVELOPMENT_TEAM "is left unset on purpose" while the next line sets `DEVELOPMENT_TEAM: "5W67TF3579"` (and dmg-from-app.sh depends on it). macos.md says the xcframework rebuilds on a changed `.udl`: no `.udl` exists. Fixed.md records bundle ids `se.agnihotri.synologyphotos.*`, the project uses `se.agnihotri.mysynologyphotos`, `...MySynologyPhotosTests`, `...PhotosCore`. HEAD is also 64 commits past `v1.0.2`, so "latest tag" in docs is not what is built.
- evidence: EXECUTED `grep` on those files and `grep PRODUCT_BUNDLE_IDENTIFIER` in the pbxproj; `find`/`git ls-files` shows no `.udl`.
- suggested fix: edit the four lines.
- suggested test: none.

### Checked and clean
- `shellcheck -x` on all 17 tracked `.sh` files: only info/style notes (SC2015 on the `have xcpretty && xcpretty || cat` idiom, SC2012 `ls`, SC2181, one unused `LIB` in ensure-xcframework.sh). `bash -n` clean. No unquoted path with spaces found, no `rm -rf` of an unguarded variable (STAGE_DIR, BUILD_DD, RESULT_BUNDLE are all non-empty derived paths).
- `xcodebuild ... | { have xcpretty && xcpretty || cat; }`: pipefail carries the xcodebuild exit code. EXECUTED a model: `(exit 65) | { have cat && cat || cat; }` gives rc 65; a failing xcpretty falls to `cat` and cannot turn a failed build into success; a build that passes and a filter that fails gives rc 0 (correct).
- ci.sh `run_macos`: every exit reasoned. no xcresult -> FAIL (stale bundle is removed first by test-app.sh); xcresulttool or the python summary failing or empty -> FAIL; rc!=0, failed>0, skipped>0 or total==0 -> FAIL; only rc==0 with total>0 and 0 failed, 0 skipped -> PASS. A non-Mac host -> SKIP (no failure). Not executed (no xcodebuild per brief). The Swift FAIL path is argued, not falsified.
- test-ci.sh really proves the gate: EXECUTED two mutated copies through `CI_SCRIPT`. Mutation A (`run_stage` records PASS on failure): 4 of 7 cases failed (failing test, unformatted code, clippy warning, CI FAIL banner). Mutation B (`FAILED` never set): the same 4 cases failed on exit code. The fmt, clippy and test stages are each covered by a case that checks the stage name. Not covered: the `scripts` stage FAIL, the no-cargo FAIL, the swift stage.
- `cargo metadata --locked --offline` rc 0 (lock matches manifests). `cargo tree -d`: duplicates are build-time or dev-only (camino x2 patch of one version, getrandom 0.2/0.3/0.4 via ring, rand and tempfile).
- project.yml vs the committed xcodeproj: every tracked Swift file (46 tests, 64 app, 1 UI test, 2 generated, plus GitVersion) has a Sources build file and there are no duplicate basenames; the three shell script phases use the post-move `../../scripts/macos/...` paths and `alwaysOutOfDate`; deployment target 26.0, team, bundle ids, search paths, hardened runtime, the Installer aggregate target and its Package DMG phase match. No drift found.
- Secrets in tracked files and history: no private keys, no long sid, SynoToken, device id or did value in any added line (regex over `git log -p -G`), only mock values (`SID123`, `SECRETSID`, `<SID>`). Only the known DSM password and Tailscale host findings exist. Local absolute paths (`/Users/<name>/...`) appear in plan documents and the team id in Fixed.md and scripts (identifier, not a secret).
- Tracked files that should be ignored: none (no dmg, xcresult, library, DS_Store). Ignored files that should be tracked: none. `.gitignore` covers `.env`, `*.pem`, `*.p12`, `syno_session*`.
- Makefile: `?=` for the deployment target (matches project.yml 26.0), `.PHONY` set. `awk 'ENDFILE'` is gawk only but the bindings regeneration was reported to give an empty diff, so the modulemap is stable.
- generate-git-version.sh: deliberately has no `set -e`, writes only on change; fine.
- Orchestrator-known items not re-reported: ffi-smoke `Connection(...)` break, the release strip failure, the DSM password and host name in tracked files.
