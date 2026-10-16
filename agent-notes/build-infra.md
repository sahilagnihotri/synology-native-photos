
---
## build-infra (worker context 1), 2026-10-16
- Self heal lives in scripts/xcodegen/ensure-xcframework.sh (called by app/project.yml build phase, unchanged, so no xcodegen regen). Staleness logic extracted to scripts/xcodegen/xcframework-staleness.sh (prints stale/fresh, exit 10/0).
- Previously only core/**/*.rs was watched. Now also core/**/Cargo.toml, core/**/*.udl, root Cargo.toml, Cargo.lock. No .udl files exist in the repo today (pattern is forward looking).
- Test: scripts/tests/test-xcframework-staleness.sh, 8 cases on fake trees in $TMPDIR with touch -t. All pass.
- Falsified: with new patterns removed, 4 of 8 cases failed (crate Cargo.toml, root Cargo.toml, Cargo.lock, .udl); restored, 8/8 pass.
- .gitignore: `git ls-files -ci --exclude-standard` after adding patterns lists nothing, so no tracked file is hit and no negation was needed.
