
---
## build-infra (worker context 1), 2026-10-16
- Self heal lives in scripts/xcodegen/ensure-xcframework.sh (called by app/project.yml build phase, unchanged, so no xcodegen regen). Staleness logic extracted to scripts/xcodegen/xcframework-staleness.sh (prints stale/fresh, exit 10/0).
- Previously only core/**/*.rs was watched. Now also core/**/Cargo.toml, core/**/*.udl, root Cargo.toml, Cargo.lock. No .udl files exist in the repo today (pattern is forward looking).
- Test: scripts/tests/test-xcframework-staleness.sh, 8 cases on fake trees in $TMPDIR with touch -t. All pass.
- Falsified: with new patterns removed, 4 of 8 cases failed (crate Cargo.toml, root Cargo.toml, Cargo.lock, .udl); restored, 8/8 pass.
- .gitignore: `git ls-files -ci --exclude-standard` after adding patterns lists nothing, so no tracked file is hit and no negation was needed.

---
## build-infra (worker context 1), VoiceOver labels, 2026-10-16
- New GridAccessibility.swift (pure label builders), wired into PhotoCellView (label set in configure, refreshed on isSelected, cleared on reuse) and ZoomSliderView (label "Thumbnail size", value as percent of range). No live photo kind exists in MediaKind, so only photo/video/item.
- Tests: GridAccessibilityTests, 6 cases. Falsified by dropping the selected suffix and mapping video to Photo: videoLabelSaysVideo and selectedStateIsAppended failed; restored, all pass.
- Full unit run: 490 total, 477 passed, 13 failed, all in sibling in-flight areas (DeleteConfirmGateTests 9, DeleteControllerTests 2, RecentlyDeletedModelTests 2). Mine all passed.
- xcodegen needed to run outside the sandbox (it writes to a system temp dir). Regenerated pbxproj is left uncommitted because it also holds DeleteConfirmGateTests entries for a sibling's untracked file.
