
## op-e-macos 2026-11-27

VF-1 and VF-9, Mac app. Suite after the work: 529 Swift Testing tests passed (514 before), TEST SUCCEEDED.

Seams (no behaviour change): `LibraryStartup.prepare` (9fad604), `SearchSession.dropForSidebarChange` and `SearchSession.run` (fdf4855), `RecentlyDeletedModel.restoreFromContextMenu` and `requestEmptyFromContextMenu` (835e183), `PhotoEditorModel.isShowingSaveFailure` (465d445). The views now call them. `ViewWiringGuardTests` pins that each view still calls its seam (source text check), since no scene can be driven here.

Falsification (exit codes only: xcodebuild failure output is truncated before the test results, a passing run is persisted; control with no mutation exited 0):
- LibraryStartup setSpace branch disabled, LibraryWiringTests: exit 65.
- dropForSidebarChange forced to return false, LibraryWiringTests: exit 65.
- run: second stale guard (after loadWindow) removed, LibraryWiringTests: exit 65.
- restoreFromContextMenu without selectForContextMenu, RecentlyDeletedModelTests: exit 65.
- Three view call sites reverted together (context menu, editor alert binding, LibraryStartup call), ViewWiringGuardTests: exit 65.
Not individually falsified: requestEmptyFromContextMenu without select, isShowingSaveFailure setter no-op, abandon restore, first run guard. They were part of one combined mutation run that exited 65.
The guard after setSearch cannot be tested: setSearch has no suspension point, so the token cannot change there.
VF-9: stale comments in GridDateSections.swift said the undated bucket is dayStart 0, it is Int64.min (0 is the real epoch day).
