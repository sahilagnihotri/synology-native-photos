
---
## delete-tests worker, 2026-10-16

Measured:
- Existing tests already covered: request raises confirm with 0 core calls, cancel makes 0 calls, confirm calls core once with exact ids/paths, confirm shown every time (DeleteControllerTests, RecentlyDeletedModelTests).
- Only callers of core delete: DeleteController.confirmDelete -> deleteAssets, RecentlyDeletedModel.confirmEmpty -> emptyRecentlyDeleted (grep of app/MySynologyPhotos). No path deletes without a confirm step.
- Gaps filled in DeleteConfirmGateTests (9 tests): confirm with no request, confirm after cancel, double confirm (both flows), restore never permanent-deletes, wording of both dialogs.
- Wording extracted (no behaviour change) to DeleteController.confirmTitle/confirmMessage and RecentlyDeletedModel.emptyConfirmMessage; the alert modifiers call them.
- Falsification (mutate source, run suite, restore):
  - DeleteController: drop empty guard + stop clearing ids in confirm + cancel not clearing + "restored" wording changed -> 4 tests failed (confirmDeleteWithoutARequest, confirmDeleteAfterCancel, confirmingTwice, everydayDeleteWording).
  - RecentlyDeletedModel: same mutations + "cannot be undone" removed -> 4 tests failed (confirmEmptyWithoutARequest, confirmEmptyAfterCancel, confirmingEmptyTwice, permanentDeleteWording).
  - restoreSelected calling emptyRecentlyDeleted -> restoreNeverCallsPermanentDelete failed.
  - Sources restored; byte-identical to pre-mutation copies.
- Full unit run after restore: 487 passed, 3 failed (OriginalImageCacheTests, ThumbnailCacheTests, sibling cache work in progress, not delete code). Before: 489 passed 0 failed.
- Running multiple mutations in one xcodebuild hung twice for 10+ min; one mutation per run with -test-timeouts-enabled YES finished in under a minute.
- xcodegen needs the sandbox off (temp file write). pbxproj regenerated; it also holds GridAccessibility entries from a sibling, so it was NOT committed by this worker.
