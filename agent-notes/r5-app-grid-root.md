## r5-app-grid-root review, 2026-11-26 17:37

Scope: `platforms/macos/MySynologyPhotos/` Grid/, RootView.swift, MySynologyPhotosApp.swift, Map/, Discovery/, Search/, Filter/, Menu/, Sidebar/, About/, plus the matching tests. Every finding is READ-ONLY (no xcodebuild, per the brief). Each stale lead from the aborted pass was re-read at HEAD; dispositions are listed at the end.

### R5-1: Returning to Library after a search, a drill-in or a Quick Filter leaves the data source on the old source, so "Library" shows search results, a collection or the filtered set
- severity: high
- confidence: high (short, unconditional call chain; no code path resets the source)
- location: platforms/macos/MySynologyPhotos/RootView.swift:773-785 (`switchSpace`), with platforms/macos/MySynologyPhotos/Session/SpaceToggle.swift:22 (`guard space != current`); callers RootView.swift:1162-1173 (`restoreCurrentRoute`) and RootView.swift:300-314 (sidebar `.grid` route)
- defect: `switchSpace` only reaches `dataSource.setSpace` through `SpaceSelection.toggle`, which returns early when the space is unchanged. `setSearch`, `setCollection`, `setFilter`, `setRemoteFilter` and `setFixedAssets` never touch `spaceSelection.current`, so every "go back to the library" path (clear the search box, click Library or the same space row, leave a drilled-in tile) is a no-op for the data source. `refreshCount` is a no-op for `.search`, `.collection` and `.remoteFilter`, and `loadWindow(0,200)` then reloads page 0 of the OLD source. `libraryDisplay` (RootView.swift:629-636) then renders `.grid` from `crawl.isComplete` plus the old source's `totalCount`.
- failure scenario: (a) type "dog", wait for results, clear the field: `restoreCurrentRoute` -> `switchSpace(.personal)` -> no-op; the grid titled "Personal" or "Library" keeps the "dog" rows, `dateSections` stays nil (no day headers), Cmd-A and Delete act on those rows. (b) Click Favorites, then Library: Library shows Favorites. (c) Apply a Quick Filter, click the same sidebar row: `activeFilter` is cleared (RootView.swift:310) but the data source stays `.filter`, so the filtered set shows with no filter hint while the filter button still shows the filled icon (`env.quickFilter` keeps its selection). (d) Session expiry or sign-out while on a collection, then login: `AppEnvironment` (and `dataSource`) is created once in `MySynologyPhotosApp.init`; the new `LibraryView.task` (RootView.swift:293-299) only calls `refreshCount`, so the old source is still active. Only switching Personal to Shared or applying/clearing a Quick Filter happens to repair it.
- evidence: READ-ONLY. `SpaceToggleTests.toggleToSameSpaceIsNoOp` pins the early return and no test drives a search -> clear -> Library sequence.
- suggested fix: make `switchSpace` (and the initial `.task`) call `env.dataSource.setSpace(space)` whenever the data source is not already a `.space(space)` source (expose `isShowingSpace(_:)`), or have `restoreCurrentRoute` call `setSpace` directly. Reset `dataSource` (and quickFilter, searchFilters, spaceSelection) on sign-out or when the auth phase leaves `.valid`.
- suggested test: coordinator-level or `WindowedDataSource` test: `setSearch("a")`, load a page, then run the same sequence `switchSpace` runs for the current space, assert `dateSections != nil` and `item(at: 0)` is a library asset. Fails today.

### R5-2: A search, collection or server-side filter with a first page of 200 or more results shows the spinner forever, and page 2 can never load
- severity: high
- confidence: medium (assumes the NAS honours `limit`; `fetch_assets_for` passes it straight through, core/photoscore/src/lib.rs:576-615)
- location: platforms/macos/MySynologyPhotos/Grid/WindowedDataSource.swift:209-210, :215-216, :241-242; platforms/macos/MySynologyPhotos/RootView.swift:603-611, :649-652 (`.importing` while `!isReady`)
- defect: for the three live sources `isReady = rows.count < limit` and `totalCount = max(totalCount, offset + rows.count)`. A first page of exactly `pageSize` (200) rows therefore leaves `isReady == false`, and the content router treats that as "Searching..." / "Loading..." / "Filtering..." so the grid is never mounted. Even if it were, `item(at:)` refuses indices >= `totalCount` (WindowedDataSource.swift:267) and prefetch only covers indices that exist, so no code path ever asks for offset 200.
- failure scenario: open a person, tag, place or Favorites with 200 or more photos, run a search that matches 200 or more, or apply a person or place filter with 200 or more matches: the spinner never resolves. 1 to 199 results work, which hides it in small test sets. (Real libraries of tens of thousands will hit this on the first Favorites or tag click.)
- evidence: READ-ONLY. `WindowedDataSourceTests.collectionWindowStaysNotReadyOnAFullPage` (WindowedDataSourceTests.swift:186) asserts `isReady == false` for a full page, so a green test encodes the behaviour that produces the spinner.
- suggested fix: make a live source displayable once its first page has returned (`isReady = true` after any page) and keep a separate `hasMore`; when the last resident index is within a threshold of `totalCount` and `hasMore`, fetch the next page and grow `totalCount` (one sentinel row or an unknown total mode).
- suggested test: fake returns 250 rows; after `loadWindow(0,200)` assert the display route is grid and that requesting index 199 triggers a fetch of offset 200 and `totalCount` reaches 250. Invert the pinned test.

### R5-3: No generation check in `loadWindow` or `schedulePageLoad`: a page fetched under an old snapshot of the data can land beside pages from a newer one, giving the same asset at two indices and a snapshot crash
- severity: high
- confidence: medium (the crash needs an unfortunate interleaving, but the interleaving needs no exotic timing; the duplicate-identifier trap is documented NSDiffableDataSourceSnapshot behaviour, not executed here)
- location: platforms/macos/MySynologyPhotos/Grid/WindowedDataSource.swift:195-257 (writes at :251-252 after the await), :395-410 (`schedulePageLoad`, its source check at :407 runs BEFORE the await and `defer` at :404 removes a marker that may belong to the next generation); platforms/macos/MySynologyPhotos/Grid/PhotoGridController.swift:712-717 (`appendItems` with no uniqueness guard)
- defect: `loadWindow` reads `source` into a switch, awaits the core, then unconditionally writes `resident[offset+i]`, `loadedPages` and (live sources) `totalCount` and `isReady`. Nothing compares a generation or the source after the await, and `reload()` keeps an equal source value so an equality check would not catch it anyway. `prefetchItemsAt` (PhotoGridController.swift:762) calls `loadWindow` directly with no check at all. `identifier(forAbsolute:)` builds `AssetItemID` from the resident row, so two resident indices holding the same asset give a duplicate identifier.
- failure scenario: (1) Shifted index without any late response: the library is open, pages 0 to 5 resident; a periodic or activation reconcile (RootView.swift:872-876) writes 3 new photos into the local index while it runs; the user scrolls and page 6 is fetched after the insert, so its first rows are the last rows of the already-resident old page 5. `applySnapshot` (run by the prefetch task) then appends the same `AssetItemID` twice and NSDiffableDataSourceSnapshot traps. `reload()` only runs after the reconcile finishes, so the window is the whole reconcile. (2) Late response: a prefetch `loadWindow(4000)` is in flight, a delete or Refresh runs `reload()` and reloads page 20, then the old response lands and overwrites indices with pre-reload rows. (3) Search: slow `loadWindow` for "a" finishing after `setSearch("ab")` writes "a" rows and bumps `totalCount = max(...)` of the new search.
- evidence: READ-ONLY
- suggested fix: add a `generation` counter incremented in `resetResident()` and every `set*`; capture it before the await in `loadWindow` and drop the result if it changed. De-duplicate in `applySnapshot` (or build identifiers from `(space, serverId)` plus a per-index fallback) so a duplicate can never reach the snapshot. Make the `pagesInFlight` removal generation aware.
- suggested test: `FakePhotosCore` whose `fetchAssets` suspends on a continuation; start `loadWindow`, call `reload()`, resume the old fetch, assert `item(at:)` and `totalCount` are unchanged. A second test: load page 0, mutate the fake so rows shift by 2, load page 1, call `applySnapshot` and assert no duplicate identifiers (today it traps).

### R5-4: Duplicate date-section identifier `.day(0)` when the library holds a photo dated within a day of the Unix epoch and any photo with no date
- severity: medium
- confidence: medium (core arithmetic read in persistence, crash by documented diffable behaviour; not executed)
- location: platforms/macos/MySynologyPhotos/Grid/PhotoGridController.swift:673-675 (`proposedSections.append(.day(section.dayStart))`); core/persistence/src/assets.rs:446-466 (`date_histogram`)
- defect: the histogram buckets with `taken_at / 86400` (SQLite integer division truncates toward zero) and appends the NULL-`taken_at` bucket with `day_start = 0`. A real row with `taken_at` in (-86400, 86400) also yields `day_start = 0`, so the histogram contains two buckets with `dayStart == 0`. `GridSectionID.day(0)` is then appended twice to `snapshot.appendSections`, which requires unique section identifiers. The same truncation merges the 172 798 seconds around the epoch into one bucket, so the "UTC day" header for pre-1970 and epoch-adjacent photos is wrong (all show "Unknown Date" because the formatter treats 0 as unknown).
- failure scenario: a photo or video imported with a zero or tiny timestamp (common for files with stripped metadata) plus any asset with a NULL `taken_at`: opening Library traps in `appendSections` (or at best both buckets render as two "Unknown Date" sections). Pre-1970 photos (taken_at negative) are bucketed with day -0 and labelled Unknown Date.
- evidence: READ-ONLY
- suggested fix: give the unknown bucket its own identifier (`GridSectionID.unknown`, or `Int64.min`) instead of reusing 0, and use floor division (`(taken_at - ((taken_at % 86400) + 86400) % 86400)`) in the core. Cross-area: the core half belongs to the persistence reviewer.
- suggested test: histogram with `[DayCount(dayStart: 0, count: 2), DayCount(dayStart: 0, count: 1)]` driven through `applySnapshot` must not trap; a core test with `taken_at = 100` and a NULL row asserting two distinct bucket keys.

### R5-5: An active search overlays every other sidebar route, because the sidebar change handler never clears `activeSearch`
- severity: medium
- confidence: high
- location: platforms/macos/MySynologyPhotos/RootView.swift:300-338 (no reset of `activeSearch`, `searchQuery`, `searchTask` or `env.searchFilters`), :603 (`libraryDisplay` checks `activeSearch` before the route), :737 and :753
- defect: `onChange(of: sidebarSelection)` clears drill-in, map cluster and `activeFilter` but not the search. `libraryDisplay` returns the search branch whenever `activeSearch != nil`, whatever the route.
- failure scenario: search "beach", then click People, Map or Recently Deleted: the content area keeps showing the search grid titled "Search: beach", the delete toolbar button stays available, and Cmd-A and Delete act on the search rows while the sidebar highlights another view. Clicking Library does nothing visible (see R5-1) while the title still says "Search: beach".
- evidence: READ-ONLY
- suggested fix: on any sidebar change set `searchQuery = ""`, `activeSearch = nil`, cancel `searchTask`, `env.searchFilters.clear()`, then restore the route (after fixing R5-1).
- suggested test: set `activeSearch`, change `sidebarSelection` to `.recentlyDeleted`, assert the display is `.recentlyDeleted` (needs the display decision extracted into a pure function, like `RootRouter`).

### R5-6: `reload()` does not reset `totalCount` for live sources, so a delete from a search, collection or remote-filter grid leaves permanent blank cells
- severity: medium
- confidence: high
- location: platforms/macos/MySynologyPhotos/Grid/WindowedDataSource.swift:298-301 (`reload`), :182-186 (`refreshCount` no-op), :210, :216, :242 (`max`)
- defect: `reload()` clears `resident` and calls `refreshCount()`, a no-op for `.collection`, `.search` and `.remoteFilter`, so `totalCount` keeps its old value. `loadWindow` only ever raises it with `max`. `refreshCurrentGrid` (RootView.swift:854-859) uses this path after every confirmed delete, an undo, a Refresh and the periodic sync.
- failure scenario: in a collection or search grid with 50 photos, delete 3 and confirm. `totalCount` stays 50, 47 rows load, indices 47 to 49 are blank placeholders whose page is already marked loaded, so they never fill. They are counted by Cmd-A and the "N selected" label and each further delete adds three more.
- evidence: READ-ONLY
- suggested fix: in `reload()` reset `totalCount = 0; isReady = false` for the live-source cases before reloading (as `setCollection` does), and set `totalCount = offset + rows.count` when the page is short.
- suggested test: `setCollection`, load 5 rows, remove 2 in the fake, `reload()` then `loadWindow`, assert `totalCount == 3`.

### R5-7: The debounced search cannot be cancelled once the sleep ends, so clearing the box mid-search or typing again lets an older result win and can leave `activeSearch` set with an empty field
- severity: medium
- confidence: medium
- location: platforms/macos/MySynologyPhotos/RootView.swift:343-367 (handler), :1097-1106 (`runSearch`)
- defect: `searchTask?.cancel()` only helps while the task is in `Task.sleep`. After the sleep `runSearch` runs `setSearch`, `loadWindow`, `applySnapshot` and finally assigns `activeSearch = keyword`, with no `Task.isCancelled` or generation check; the awaited core calls do not honour cancellation. The empty-field branch has `guard activeSearch != nil else { return }`, so clearing while the first search is still in flight does nothing.
- failure scenario: (a) type "dog", the 300 ms debounce fires, the NAS is slow; clear the field: `activeSearch` is still nil so the handler returns; the search finishes and sets `activeSearch = "dog"` with an empty search box and no obvious way out. (b) Type "do", pause, type "dogs": both `runSearch` calls interleave on the main actor, and if "do" finishes last it sets `activeSearch = "do"` and (via R5-3) its rows overwrite "dogs".
- evidence: READ-ONLY
- suggested fix: one `searchGeneration` token, checked after every await in `runSearch` before committing `activeSearch`; have the empty-field branch bump the token even when `activeSearch` is nil.
- suggested test: a coordinator-level test with a fake search that suspends, clearing the query before resume, asserting `activeSearch == nil` afterwards.

### R5-8: Cmd-Z undo restores by filename and by the recycle entry's "deletedAt", which is the file mtime, so it can restore a different photo than the one just deleted; the tests encode the assumption
- severity: medium
- confidence: low to medium (depends on DSM keeping the original mtime when it moves a file into the recycle bin; I could not check against the NAS, which is off limits)
- location: platforms/macos/MySynologyPhotos/Grid/DeleteController.swift:189-196 and :211-228; core/synology-api/src/recycle.rs:270 (`deleted_at: entry.mtime`) and :281 (sort by it)
- defect: `undoLastDelete` fetches the first `max(2n, 200)` entries of the bin sorted by `deleted_at`, then for each remembered filename claims the newest matching entry. But `deleted_at` is `entry.mtime` from File Station, i.e. the file's modification time. A move into `#recycle` normally preserves mtime, so "newest" means newest by when the photo was taken or modified, not by when it was deleted. The comment "the just-deleted entries are the newest in the bin" is therefore unsupported.
- failure scenario: you delete `IMG_0001.HEIC` (a 2019 photo). The bin already holds another `IMG_0001.HEIC` from a 2023 photo deleted last month (iPhone counters repeat, two phones). Cmd-Z picks the entry with the larger mtime, the 2023 photo, and restores that one, leaving the photo you just deleted in the bin and silently resurrecting another; the undo is then cleared. With more than 200 bin entries of newer mtime, the 2019 photo is not on the first page at all, the matcher finds nothing, the undo is cleared (DeleteController.swift:192-195) and nothing is shown to the user.
- evidence: READ-ONLY. `DeleteControllerTests` build their `RecycleItem.deletedAt` values from the same belief (`recycle("#recycle/a-new", "a.jpg", 200)`), so they cannot falsify it.
- suggested fix: match on something stable (the original relative folder plus filename, or record the recycle path set before and after the delete), and treat a no-match as an error message, not a silent clear. Verify the mtime behaviour on the NAS with a recorded listing before relying on it.
- suggested test: a fixture built from a recorded DSM recycle listing where the deleted file's mtime is older than an unrelated same-named entry.

### R5-9: Sign Out clears the Keychain under `env.host`, which is the host at launch and is empty after a first login, so the stored session survives Sign Out
- severity: medium
- confidence: high on the reading; the user-visible effect depends on how the SID is stored
- location: platforms/macos/MySynologyPhotos/RootView.swift:1014 (`keychainHost: env.host`), :78 and :99 (`let host`), platforms/macos/MySynologyPhotos/MySynologyPhotosApp.swift:56-64 (`storedHost` is `""` when nothing was stored); platforms/macos/MySynologyPhotos/Auth/AuthStateMachine.swift:87 (`KeychainSID.save(session, host: host)` uses the host typed in the login form)
- defect: `AppEnvironment.host` is a `let` set once at launch from the previously stored session. On a fresh install, after a prior sign-out, or when the user logs in to a different host, it is `""` or stale, while the login saves the SID under the host typed into the form. `SignOutController` then calls `KeychainSID.clear(host: "", username:)` inside `try?`, which clears nothing and reports nothing.
- failure scenario: first launch, log in with "Remember me", click Sign Out: the server logout invalidates the session but the SID and SynoToken stay in the Keychain under the real host; the next launch `loadMostRecentAccount` finds them and attempts a restore. The user believes the credentials were removed. (If the SID is still valid server-side, for example when logout failed offline, the app signs straight back in.)
- evidence: READ-ONLY
- suggested fix: derive the host from the live session or the auth state machine at sign-out time (record the host in `AuthPhase.valid` or on `AuthStateMachine` when login succeeds), and make `AppEnvironment.host` a `var` updated on login.
- suggested test: `SignOutControllerTests` variant that signs in with host A while `env.host` is empty and asserts the Keychain entry for host A is gone.

### R5-10: `prefetchItemsAt` calls `loadWindow` directly, bypassing the loaded-page and in-flight dedupe, so every prefetch tick refetches a page and rebuilds the whole snapshot
- severity: medium
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Grid/PhotoGridController.swift:755-766
- defect: only `schedulePageLoad` consults `loadedPages` and `pagesInFlight`; the prefetch handler computes the page of the lowest index and always calls `loadWindow`, then `applySnapshot` (O(total rows) identifier build plus an O(N) `diffable.snapshot()` copy and compare on the main actor). The code's own comment says AppKit fires prefetch repeatedly while the grid is idle, and its "skip when rows empty" guard never triggers because an already resident page returns its rows again.
- failure scenario: scrolling or just sitting on a person, tag, search or remote-filter grid: each prefetch callback sends a fresh `Browse.Item` or `Search` request to the NAS for the page already on screen (live sources), and on a 100k library each tick rebuilds and compares a 100k identifier list on the main thread.
- evidence: READ-ONLY
- suggested fix: route prefetch through the same dedupe as `item(at:)` (skip pages in `loadedPages`) and call `applySnapshot` only when new rows were merged.
- suggested test: fake counting `fetchAssets` calls; call `collectionView(_:prefetchItemsAt:)` three times for the same index path and assert one fetch.

### R5-11: Delete resolves the selection by index against a data source that may already have switched under a still-visible old grid
- severity: medium
- confidence: low to medium (narrow window, no crash, still confirm-gated)
- location: platforms/macos/MySynologyPhotos/RootView.swift:1097-1106 (`runSearch`), :1116-1141 (`applyQuickFilter`), :795-800 (`switchCollection`), :854-859 (`refreshCurrentGrid`, `clearSelection` runs AFTER the awaits); platforms/macos/MySynologyPhotos/Grid/PhotoGridController.swift:448-450 (`selectedAssets`)
- defect: each switch calls `controller.clearSelection()` first, then awaits `setX` (which resets `resident` and swaps the source) and a network `loadWindow`, and only then `applySnapshot`. For the whole await the old grid stays on screen, the user can click a cell and press Delete, and `selectedAssets()` resolves that index through `residentItem(at:)` against the NEW source. In `refreshCurrentGrid` the order is reload, load, then clear the selection, so a selection made before the reload is resolved against page 0 of the new ordering while it is still set.
- failure scenario: a search takes 2 seconds; during that time the old library grid is still shown, the user selects photo 5 and presses Delete. The confirm says "Delete 1 item?", and the id it deletes is whatever search result sits at index 5, not the photo highlighted. The confirm shows only a count, never names or thumbnails, so the user cannot notice. Invariant 2 still holds (confirmed, recoverable) but the item deleted is not the item seen.
- evidence: READ-ONLY
- suggested fix: capture asset ids at selection time (store ids, not indices, in the selection model), or block delete while a source switch is in flight, and clear the selection in the same synchronous step as the source swap.
- suggested test: select index 2 on the library, start `setSearch` with a fake whose `searchAssetsFiltered` suspends, resolve it, then call `selectedAssets()` and assert it does not return a search row.

### R5-12: Map annotations are validated only for non-nil, so (0,0), NaN and out-of-range coordinates reach MapKit
- severity: low
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Map/MapModel.swift:71-76; platforms/macos/MySynologyPhotos/Map/PhotoMapView.swift:61-64
- defect: `compactMap` accepts any non-nil latitude and longitude. A photo with a (0,0) "no fix" default, a latitude outside -90...90 or NaN is plotted, and `showAnnotations` then fits a world-sized region around one pin off Africa; an invalid coordinate can trip MapKit's invalid region handling.
- failure scenario: one phone photo with 0,0 EXIF: the map opens zoomed out to the whole globe with a lone pin in the Gulf of Guinea.
- evidence: READ-ONLY
- suggested fix: filter with `CLLocationCoordinate2DIsValid` and drop exactly (0,0).
- suggested test: `MapModelTests` with assets at (0,0), (91,10), (NaN,5) and one valid; assert only the valid one is published.

### R5-13: A failed count read replaces the library with "No photos", and a failed page read is invisible
- severity: low
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Grid/WindowedDataSource.swift:148-152 (`refreshCount` catch sets `totalCount = 0`, `isReady = false`, `dateSections = nil`), :254-256 (`loadWindow` returns `[]`)
- defect: the data source has no failure state, so `LibraryContentRoute.failed` can never come from a window or count read. A transient `refreshCount` error during the periodic sync (`refreshCurrentGrid`, for example a locked local database during a write) zeroes the count and the router shows the "No photos" empty-library state until the next successful sync. A failed page read leaves blank cells with no message.
- failure scenario: a database busy error during the 150 s auto-sync: the whole library is replaced by the empty state.
- evidence: READ-ONLY
- suggested fix: keep the previous `totalCount` and `dateSections` on a failed refresh and record a `lastError` that feeds the `.failed` route.
- suggested test: fake `assetCount` throws after a successful load; assert `totalCount` is unchanged and `lastError` is set.

### R5-14: The periodic and activation sync clears the user's selection and shifts the photo shown in an open detail viewer
- severity: low
- confidence: medium
- location: platforms/macos/MySynologyPhotos/RootView.swift:854-859 (`refreshCurrentGrid` ends in `clearSelection`), :898-903 (`autoSyncTick`, which checks neither `detailIndex` nor selection); detail viewer reads `env.dataSource.item(at:)` (RootView.swift:442)
- defect: every automatic sync, even when nothing changed on the NAS, wipes resident rows and the selection, and the viewer addresses the photo by absolute index.
- failure scenario: a multi-selection built over a minute vanishes at the 150 s tick, or the user is looking at photo 10 in the viewer, the sync inserts 2 new photos at the top and the viewer silently shows a different photo at index 10 (Delete in the viewer deletes what is displayed at press time, so it stays confirmed, but the swap is silent).
- evidence: READ-ONLY
- suggested fix: skip the automatic reload while `detailIndex != nil` and when the reconcile reported no change; keep the selection by asset id.
- suggested test: `autoSyncTick` with a no-change reconcile leaves `controller.selection` intact.

### R5-15: Tests that do not test the delete wiring, and tests that encode the defects above
- severity: low
- confidence: high
- location: platforms/macos/MySynologyPhotosUITests/ (only `PhotosCoreLinkSmokeUITests.swift`); platforms/macos/MySynologyPhotosTests/DeleteConfirmGateTests.swift and DeleteControllerTests.swift; WindowedDataSourceTests.swift:186; SpaceToggleTests.swift (`toggleToSameSpaceIsNoOp`)
- defect: `DeleteConfirmGateTests` and `DeleteControllerTests` drive `DeleteController` in isolation. Nothing exercises `DeleteConfirmModifier`, `requestDeleteSelected`, the toolbar button, the context menu item, `onDeleteRequested`, or that the alert's Delete button really routes to `confirmDelete`. By construction a bypass is unlikely (the only `deleteAssets` caller is `DeleteController.confirmDelete`, DeleteController.swift:125, confirmed by grep over the app target), but removing `.deleteConfirm(...)` at RootView.swift:407 would make the app unable to delete and still leave every test green. The project rule asks for UI tests on destructive actions. `collectionWindowStaysNotReadyOnAFullPage` and `toggleToSameSpaceIsNoOp` pin the behaviours behind R5-2 and R5-1, and the undo fixtures assume `deletedAt` is a deletion time (R5-8). No test covers a late response, an index shift, or `reload()` on a live source.
- failure scenario: the regressions above ship green.
- evidence: READ-ONLY (read every test file name and body in the area)
- suggested fix: an XCUITest against a fake-core launch mode: select, press Delete, assert the alert, Cancel keeps the photo, Delete removes it; add the race and live-source tests from R5-3 and R5-6.
- suggested test: as above; falsify by deleting the `.deleteConfirm(...)` line.

## Also noted (not scored)
- Cmd-Z: `CommandGroup(replacing: .undoRedo)` (Menu/LibraryCommands.swift:79-84) enables "Undo Delete" whenever `canUndoDelete` is true, which stays true until the next undo, so Cmd-Z in the search field restores the last deleted photos instead of undoing the text edit. Low.
- `DiscoveryTilesModel.fetchLimit = 500` (Discovery/DiscoveryTilesModel.swift:36), one call, no paging and no notice: an account with more than 500 people, places, tags or albums sees only the first 500. Low.
- `refreshCount` comment claims count, progress and histogram are "the same DB snapshot" (WindowedDataSource.swift:142-146) but they are three separate awaited calls; a write between them gives `dateSections.totalCount != totalCount` until the next refresh. Low, self-heals.
- Select All on a large library builds a 100k `Set<Int>` and `IndexPath` set and `snapshotItemCount()` copies the diffable snapshot on every key press (PhotoGridController.swift:326-329, :739-741, :856-860). Not measured. The delete confirm only lists rows that are resident (`residentItem`), so the "N selected" label can exceed the number deleted; the confirm text itself is accurate.

## Checked and clean
- Every path to `core.deleteAssets` goes through `DeleteController.confirmDelete` (only caller, DeleteController.swift:125; PhotosCoreClient.swift:79 is the wrapper). Entry points: grid Delete and Cmd-Delete key, Edit > Delete responder (`KeyHandlingCollectionView.delete`), context menu, toolbar button, detail viewer button. All reach `requestDelete`, which reads the recycle bin status fresh each time, refuses on Disabled with the notice, and warns about permanence on Unknown. `confirmDelete` re-checks `status != .disabled` and an empty id list, and clears the pending state before the call, so a double confirm deletes once.
- Delete ids are captured at request time as asset ids (not indexes), so a reload between the prompt and the confirm cannot change what is deleted (the R5-11 window is before the prompt, not after it). A `requestDelete` that throws on the status read raises no confirm and shows the error alert.
- DeleteController failure and undo errors are surfaced: `DeleteConfirmModifier` binds an alert to `errorMessage` (DeleteController.swift:270-280).
- Cmd-A in a filtered, search or cluster view selects only that source's count (`snapshotItemCount()`), not the library; delete resolves only resident rows.
- GridDateSections: prefix sums, `absoluteIndex` and `position(forAbsolute:)` binary search bounds, zero-count sections, empty histogram and one-item cases are correct by reading; no negative timestamp arithmetic exists in the Swift side (the bucketing problem is in the core, R5-4).
- PhotoSelectionModel and GridNavigation: shift ranges, anchor handling, `selectAll(count: 0)`, arrow keys at the first and last item (no wrap, no move) and `clampedCurrent` bounds are correct.
- PhotoCellView: reuse guard (`representedAssetId` check after the await, `loadTask` cancelled in `prepareForReuse` and on reconfigure) is sound; no per-cell main-thread decoding beyond `NSImage(cgImage:)`.
- `applySnapshot` has no await after its guard so concurrent calls cannot interleave; `itemIdentifiers(inSection:)` is only queried after the section lists match.
- Quick Filter and Search date bounds: start of day to end of day (23:59:59) in the local calendar, consistent in both models; a start after the end returns an empty result (harmless).
- Map cluster to asset mapping (`memberAnnotations` to `PhotoPointAnnotation.asset`), the pin rebuild guard, and the prune after a delete inside a cluster behave consistently; `MapDestinationView` rebuilds its model on re-entry so stale pins do not outlive a delete.
- PhotoDragExport and `QuickLookFilename.derive`: the filename is a single sanitised path component; the export only reads from the NAS.
- MySynologyPhotosApp: no secrets logged, store failure shows a terminal screen, restore loads the pinned cert before `restore`.

## Disposition of the stale leads
- Stale R5-1 (no generation check): kept, corrected and strengthened, now R5-3.
- Stale R5-2 (Library keeps the old source): kept, now R5-1, extended with the Quick Filter and re-login cases.
- Stale R5-3 (full page spinner): kept, now R5-2, same code and the same pinned test.
- Stale R5-4 (reload keeps totalCount): kept, now R5-6.
- Stale R5-5 (error never shown): DROPPED, fixed at HEAD (alert bound to `errorMessage`, DeleteController.swift:270-280).
- Stale R5-6 (search not cancellable): kept, now R5-7.
- Stale R5-7 (search leaks into routes): kept, now R5-5.
- Stale R5-8 (prefetch bypasses dedupe): kept, now R5-10.
- Stale R5-9 (map coordinates): kept, now R5-12.
- Stale R5-10 (errors swallowed): kept, now R5-13.
- Stale R5-11 (tests): kept, now R5-15, with the added Fixed.md-era fixtures (recycle bin status gate tests are good and cover the controller).
- Stale R5-12 (select all cost): unmeasured, listed under "Also noted".
- Stale R5-13 (sync clears selection): kept, now R5-14.
- Stale R5-14 (500 tile truncation): still present, listed under "Also noted".
