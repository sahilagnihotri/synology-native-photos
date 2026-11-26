# fs-macos-app notes

Method note: tests that introduce a new seam type or method (R4-6, R5-5/R5-7, R4-4) "failed" first as a compile error (the API did not exist). Behavioural fail-first runs were observed for R4-1, R4-3, R5-1, R5-2/R5-6, R4-5, R4-2; R5-4 and R5-12 were falsified by temporarily removing the fix (both tests failed, then the fix was restored). Unit tests only; the UI test target was never run. Counts below come from the Swift Testing line only ("Test run with N tests in M suites passed"); the 6 XCTest cases were part of the baseline and the run reported TEST SUCCEEDED.

### R4-1 (and R5-9): FIXED
- commit: 448be63
- test: SignOutControllerTests.signOutClearsSessionSavedUnderLoginHostWhenLaunchHostIsEmpty
- failed before the fix: `Failing tests: SignOutControllerTests.signOutClearsSessionSavedUnderLoginHostWhenLaunchHostIsEmpty()`
- passes after: SignOutControllerTests suite, no failing tests
- fix: AuthStateMachine records `sessionHost` on login and restore; SignOutController clears under `auth.sessionHost ?? keychainHost`.
- left open: R4-1 also suggests clearing other stored sessions in `attemptLogin` (several items make `loadMostRecentAccount` arbitrary). Not done, single account assumption; NEEDS RULING if multi-host use matters.

### R4-3: FIXED
- commit: 7b296d3
- test: LoginViewModelTests.pinStoreIsIsolatedFromRealApplicationSupportUnderTests
- failed before the fix: `LoginViewModelTests.pinStoreIsIsolatedFromRealApplicationSupportUnderTests()`
- fix: under the unit test host `KeychainCertPin` uses `<tmp>/SynologyNativePhotos-tests/pins`. `loginTargetsTypedHostNeverTheCertSubject` now uses `https://pin-test-typed.invalid:5001` instead of the real NAS host.
- changed tests: that host string only.
- left open: none. The real pin file for the user's NAS host is still present (checked).

### R5-1: FIXED
- commit: 9fad604
- test: SpaceToggleTests.toggleToCurrentSpaceAfterASearchRestoresTheSpaceSource
- failed before the fix: 3 expectations failed (totalCount, dateSections, item(at: 0))
- fix: `WindowedDataSource.isShowingSpace`; `SpaceSelection.toggle` re-applies the space when the source is not that space's library; LibraryView `.task` does the same after a re-login. `toggleToSameSpaceIsNoOp` still passes (it only pins "no reload while already showing the space").
- left open: R5-1 also suggests resetting quickFilter/searchFilters on sign-out. Not done (re-login case covered by the source check only).

### R5-5 and R5-7: FIXED (one commit, same view code)
- commit: fdf4855
- tests: SearchSessionTests (3 tests in RootRouterTests.swift)
- failed before the fix: compile error, `SearchSession` did not exist
- fix: `SearchSession` (active keyword plus generation token). Sidebar change cancels an active search and clears the box and filters; every search run checks its token after each await and only commits if current; clearing the box always invalidates in-flight runs; a superseded run that already pointed the data source at its keyword restores the current route when the box is empty.
- left open: the view wiring itself (RootView) is not unit tested; only SearchSession is. A stale run's rows can still land in the data source (R5-3, not in my queue).

### R5-2 and R5-6: FIXED (one commit, same code)
- commit: 25fac1e
- tests: WindowedDataSourceTests.collectionWindowIsReadyOnAFullPageAndKeepsPagingToTheEnd, searchAndRemoteFilterAreReadyOnAFullPage, reloadOfALiveSourceDropsTheStaleTotal, reloadWithAFullPageDoesNotKeepAnOversizedTotal
- failed before the fix: all four (7 expectation failures listed)
- changed tests: `collectionWindowStaysNotReadyOnAFullPage` asserted the defect (isReady false on a full page, the spinner forever). Replaced by `collectionWindowIsReadyOnAFullPageAndKeepsPagingToTheEnd`.
- fix: live sources are ready after any page. A full page holds `totalCount` one row past what is known (a spare trailing cell the grid scrolls onto to request the next page); a short page fixes the total exactly. `reload()` marks the total stale so the next page 0 read replaces it. The grid's prefetch handler now also re-applies the snapshot when the total changed with an empty page, so the spare cell disappears.
- left open: NOT measured in the running app (no UI run). Side effect: for a live source whose size is an exact multiple of the page size, the grid briefly shows one blank trailing cell and the "N selected" count of Select All includes it until the empty page returns. Decision for Sahil if that is unacceptable: an explicit unknown total mode.

### R4-5: FIXED
- commit: 9748c09
- tests: RecentlyDeletedModelTests.partialRestoreFailureReloadsKeepsTheMessageAndRetriesOnlyTheRest, partialPermanentDeleteFailureReloadsAndKeepsTheMessage. This also adds the previously missing "restored N of M" message test (TODO.md item): the model now keeps the core message through the reload.
- failed before the fix: both tests listed as failing
- fix: both catch blocks reload the list, restore the error message after the reload, and a failed restore also runs the library refresh. FakePhotosCore gained `recycleOpRemovesBeforeFailing` to model partial progress.
- left open: the core still does not reindex after a partial restore (Rust, not mine); the app refreshes the library but the NAS index may lag.

### R4-6: FIXED
- commit: 835e183
- tests: RecentlyDeletedModelTests.contextMenuOnAnUnselectedItemTargetsOnlyThatItem, contextMenuOnASelectedItemKeepsTheSelection
- failed before the fix: compile error (`selectForContextMenu` missing)
- fix: right click on an unselected entry replaces the selection with that entry; on a selected entry keeps the selection.

### R4-2: FIXED
- commit: 8b46a9c
- tests: DetailImageLoaderTests.aLateLoadForThePreviousPhotoDoesNotOverwriteTheCurrentOne, aLateFullResolutionForThePreviousPhotoIsDiscarded
- failed before the fix: both listed as failing
- fix: generation counter in `DetailImageLoader.load`; the late display or full resolution result is dropped unless still current for the same asset. The unstructured zoom `Task {}` in the view is not cancelled (the generation check makes that safe).

### R4-11 and R4-12: FIXED (one commit, same files)
- commit: 465d445
- tests: PhotoEditorModelTests.aFailedSaveExposesAUserVisibleMessageUntilDismissed, editedFilenameIncludesTheDate
- failed before the fix: compile error (new members) and the date format expectation
- changed tests: `editedFilenameStructureAndSanitization` asserted a six digit time stamp; it now asserts `yyyyMMdd-HHmmss` (15 characters). The old assertion encoded the collision risk.
- fix: model exposes `saveFailureMessage` and `dismissSaveFailure`, the editor shows an alert; the filename is `<base>-edited-yyyyMMdd-HHmmss.jpg`.
- left open: R4-12 second half (treat a reindex failure after a successful upload as non fatal, so a retry does not upload a second copy) is in the Rust core path of `saveEditedPhoto`, not changed. NEEDS RULING: either a core change or an app side note after a failed save that the upload may have succeeded.

### R4-4: FIXED
- commit: 1e86fdd
- test: DetailVideoCoordinatorTests.aDismantledCoordinatorIgnoresALateCompletion
- failed before the fix: compile error (`invalidate`, `isShowing`, `loadTask` missing)
- fix: the coordinator keeps the load task, `dismantleNSView` calls `invalidate()` (clears `lastAssetId`, cancels the task), and the late completion checks `isShowing` and `Task.isCancelled` before `play()`.
- left open: the real AVPlayer path is not exercised; the test pins the guard only.

### R5-4 (app half): FIXED
- commit: 1016098
- test: GridDateSectionsTests.adjacentBucketsWithTheSameDayStartMergeIntoOneSection
- failed before the fix: 4 expectations (observed with the merge disabled)
- fix: `GridDateSections.init` merges adjacent histogram buckets with the same dayStart, so section identifiers are unique whatever the core returns. Non adjacent duplicates are not handled (the core returns buckets sorted).

### R5-12: FIXED
- commit: 80363c0
- test: MapModelTests.dropsNullIslandNaNAndOutOfRangeCoordinates
- failed before the fix: observed with the guard removed
- fix: `MapModel.load` drops non finite, out of range and exactly (0,0) coordinates.

## Full suite
- After the last commit: `Test run with 512 tests in 54 suites passed`, `** TEST SUCCEEDED **`, 0 failed, 0 skipped. Baseline was 492 Swift Testing tests in 52 suites plus 6 XCTest.
