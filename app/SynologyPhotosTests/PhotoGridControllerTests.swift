import Testing
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct PhotoGridControllerTests {
    // unitId intentionally equals id here: several tests in this file key
    // FakePhotosCore's per-asset delay/result dictionaries by the value
    // ThumbnailCache passes through as unitId (asset.unitId, not asset.id),
    // so keeping them equal in this fixture is what lets those tests target
    // a specific asset's simulated network behavior by its id.
    private func asset(_ id: Int64) -> Asset {
        Asset(id: id, unitId: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    /// Writes a solid-color PNG with a distinct aspect ratio so a decoded
    /// thumbnail can be told apart from another asset's without comparing
    /// raw pixels: after `ThumbnailCache` downsamples to a `.sm` (240px)
    /// bound, the wide/tall ratio survives even though absolute pixel
    /// dimensions do not.
    private func writePNG(width: Int, height: Int) -> String {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cell-\(UUID()).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return url.path
    }

    @Test func snapshotReflectsLoadedWindow() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<120).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 120, total: 120, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 60)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 60)
        await controller.applySnapshot()
        // One item identifier per index across the whole space (120), not
        // per loaded window (60): the placeholder-id strategy keeps the
        // snapshot count equal to totalCount so scrollbar geometry is
        // correct as soon as the count is known, regardless of how much of
        // the window has actually loaded.
        #expect(controller.snapshotItemCount() == 120)
    }

    @Test func cellConfigureDoesNotCrashWithoutImage() {
        let cell = PhotoCellView()
        _ = cell.view
        let cache = ThumbnailCache(client: PhotosCoreClient(core: FakePhotosCore()))
        cell.configure(asset: asset(1), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 1)
    }

    /// `totalCount` reflects the full space size even before every row has
    /// been paged in; only `loadWindow` populates `resident` rows.
    @Test func snapshotCountMatchesTotalCountBeforeAnyWindowLoads() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 50)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await controller.applySnapshot()
        #expect(controller.snapshotItemCount() == 500)
    }

    /// The classic grid-reuse bug: a cell configured for asset A, then
    /// reused for asset B before A's thumbnail load resolves, must not
    /// paint A's late-arriving image over B.
    ///
    /// This forces the actual race rather than hoping for one: asset A's
    /// fake thumbnail load is held up by an artificial delay, so it is
    /// provably still in flight at the moment the cell is reused for asset
    /// B (whose load has no delay and resolves immediately). Only after B's
    /// image has been painted does the test wait for A's delayed load to
    /// finally resolve, then asserts A's image never overwrote B's. A and B
    /// use images with different aspect ratios so the assertion is on the
    /// actual painted pixels, not just on `representedAssetId` (which the
    /// guard's completion closure never touches, so it alone would not
    /// catch a broken guard).
    ///
    /// Without the `representedAssetId == targetId` recheck in
    /// `PhotoCellView.configure`'s completion, A's delayed load would
    /// unconditionally paint into `thumbView` after B's fast load already
    /// painted B's image, and this test would fail: it was run once with
    /// that guard line commented out to confirm the failure, then restored.
    @Test func prepareForReuseDropsStaleLoadThatResolvesAfterReuse() async throws {
        let fake = FakePhotosCore()
        let widePath = writePNG(width: 800, height: 200) // asset A: 4:1
        let squarePath = writePNG(width: 400, height: 400) // asset B: 1:1
        defer {
            try? FileManager.default.removeItem(atPath: widePath)
            try? FileManager.default.removeItem(atPath: squarePath)
        }

        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let cell = PhotoCellView()
        _ = cell.view

        // Asset A's load is held up well past the point where the test will
        // have already reused the cell for B and let B's load resolve.
        // Results are keyed by asset id (not the shared `thumbnailResult`)
        // so A's call still resolves to A's own wide image after it wakes,
        // even though B's result is assigned in the meantime.
        fake.thumbnailDelayByAssetId[1] = .milliseconds(150)
        fake.thumbnailResultByAssetId[1] = .success(ThumbnailData(cachedPath: widePath, bytes: Data()))
        cell.configure(asset: asset(1), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 1)

        // Give asset A's task a chance to start (and reach the `await` on
        // the artificial delay) without giving it anywhere near enough time
        // to finish; this is what makes the reuse below land while A is
        // still genuinely in flight, unlike a bare `Task.yield()`.
        try await Task.sleep(for: .milliseconds(20))

        // Simulate the collection view recycling this cell for a different
        // index before asset 1's async load has resolved.
        cell.prepareForReuse()
        #expect(cell.representedAssetId == -1)
        #expect(cell.displayedImage == nil)

        // Asset B has no delay, so its load resolves and paints almost
        // immediately.
        fake.thumbnailResultByAssetId[2] = .success(ThumbnailData(cachedPath: squarePath, bytes: Data()))
        cell.configure(asset: asset(2), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 2)

        try await Task.sleep(for: .milliseconds(60))
        let afterB = try #require(cell.displayedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(afterB.width == afterB.height) // B's square aspect ratio, not A's 4:1.

        // Now let asset A's delayed load actually resolve. Its guard check
        // (representedAssetId == 1) must fail since the cell now reads 2,
        // so the wide image must never land, and B's square image must
        // still be the one displayed.
        try await Task.sleep(for: .milliseconds(150))
        #expect(cell.representedAssetId == 2)
        let final = try #require(cell.displayedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(final.width == final.height)
    }

    /// Re-`configure`-ing the same cell in place (no `prepareForReuse` in
    /// between, e.g. a reconfigure from a diffable snapshot apply) must
    /// still cancel the previous load rather than racing two loads against
    /// one image view.
    @Test func reconfiguringInPlaceReplacesRepresentedId() {
        let cache = ThumbnailCache(client: PhotosCoreClient(core: FakePhotosCore()))
        let cell = PhotoCellView()
        _ = cell.view

        cell.configure(asset: asset(10), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 10)

        cell.configure(asset: asset(11), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 11)
    }

    /// The critical safety proof: mid-crawl, the grid must never present a
    /// partial library as complete. Even though the snapshot's item count
    /// climbs to match `totalCount` (a partial count that will keep
    /// growing as the crawl continues), `snapshotIsComplete` must stay
    /// false, because it is sourced from `dataSource.isReady` (the crawl
    /// barrier), not from any row count. A regression that goes back to
    /// deciding completeness by reading `totalCount` unconditionally would
    /// make this test fail: `snapshotItemCount()` alone equalling
    /// `totalCount` is exactly the false signal this guards against.
    @Test func snapshotIsNotCompleteWhileCrawlIsInProgress() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<100).map { asset(Int64($0)) }
        // Mid-crawl: 100 rows already indexed, but the barrier has not
        // flipped, so the true library size may still be far larger.
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 100, total: 1000, complete: false)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 50)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view

        await ds.refreshCount()
        #expect(ds.isReady == false)

        await ds.loadWindow(offset: 0, limit: 50)
        await controller.applySnapshot()

        // The grid does show the rows it has: browsing is not blocked on
        // the crawl finishing.
        #expect(controller.snapshotItemCount() == 100)
        // But it must not be reported as the complete library.
        #expect(controller.snapshotIsComplete == false)
    }

    /// Once the barrier flips, a fresh `applySnapshot()` call picks that up
    /// and reports the grid as complete, driven by the same `isReady` read
    /// that reported `false` above rather than by any count comparison.
    @Test func snapshotBecomesCompleteOnceBarrierFlips() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<100).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 100, total: 1000, complete: false)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 50)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view

        await ds.refreshCount()
        await controller.applySnapshot()
        #expect(controller.snapshotIsComplete == false)

        // The crawl finishes: the core now reports the barrier as complete
        // with the library's true final size.
        fake.assets[.personal] = (0..<1000).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 1000, total: 1000, complete: true)
        await ds.refreshCount()
        #expect(ds.isReady == true)

        await controller.applySnapshot()
        #expect(controller.snapshotIsComplete == true)
        #expect(controller.snapshotItemCount() == 1000)
    }

    /// Reproduces the real-device crash: `RootView`'s `.task` calls
    /// `applySnapshot()` unconditionally right after login/crawl, but the
    /// grid is only added to the view hierarchy once `env.crawl.isComplete`
    /// is true, so `PhotoGridController.view` (and therefore `viewDidLoad()`,
    /// which builds `diffable`) may not have run yet at that point. Calling
    /// `applySnapshot()` before touching `controller.view` at all simulates
    /// exactly that ordering: `diffable` is still nil.
    ///
    /// Before the fix this force-unwrapped `diffable` and crashed. After the
    /// fix it must no-op safely (no crash, count stays 0, nothing marked
    /// complete) and remember that a snapshot is owed. Once the view finally
    /// loads (simulated here by reading `controller.view`, which triggers
    /// `viewDidLoad()`), the controller must catch up on its own and the
    /// snapshot must reflect the data source without any further
    /// `applySnapshot()` call from the test.
    @Test func applySnapshotBeforeViewLoadsDefersThenCatchesUpOnceViewLoads() async throws {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<80).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 80, total: 80, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 40)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)

        // Populate the data source the way `LibraryView`'s `.task` does,
        // still without ever touching `controller.view`.
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 40)

        // This is the crashing call site: `applySnapshot()` before the view
        // (and therefore `diffable`) exists. Must not crash.
        await controller.applySnapshot()
        #expect(controller.snapshotItemCount() == 0)
        #expect(controller.snapshotIsComplete == false)

        // The view finally loads (SwiftUI adding `PhotoGridView` once
        // `env.crawl.isComplete` flips). `viewDidLoad()` must apply the
        // pending snapshot itself, with no further `applySnapshot()` call
        // from here.
        _ = controller.view
        try await Task.sleep(for: .milliseconds(50))

        #expect(controller.snapshotItemCount() == 80)
        #expect(controller.snapshotIsComplete == true)
    }

    /// After the deferred catch-up runs once, `applySnapshot()` must still
    /// work normally for later calls (e.g. further prefetch pages loading,
    /// or a space toggle), not get stuck treating every call as pending.
    @Test func applySnapshotKeepsWorkingAfterDeferredCatchUp() async throws {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<40).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 40, total: 40, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 40)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)

        await ds.refreshCount()
        await controller.applySnapshot() // deferred: no view yet
        _ = controller.view // viewDidLoad() catches up
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.snapshotItemCount() == 40)

        // Simulate the space growing (e.g. more of the library gets
        // crawled) and a later, ordinary applySnapshot() call.
        fake.assets[.personal] = (0..<90).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 90, total: 90, complete: true)
        await ds.refreshCount()
        await controller.applySnapshot()
        #expect(controller.snapshotItemCount() == 90)
        #expect(controller.snapshotIsComplete == true)
    }

    // MARK: - identifiersChanged (pure guard behind the flicker fix)

    /// The exact no-scrolling flicker scenario: a prefetch tick recomputes
    /// the same identifier list that is already applied. The guard must
    /// report "no change" so `applySnapshot()` skips `diffable.apply(...)`
    /// and the visible cells are never reconfigured.
    @Test func identifiersChangedIsFalseForIdenticalLists() {
        let ids = [AssetItemID(space: .personal, serverId: 1), AssetItemID(space: .personal, serverId: 2)]
        #expect(PhotoGridController.identifiersChanged(current: ids, proposed: ids) == false)
    }

    @Test func identifiersChangedIsTrueWhenARowIsAdded() {
        let current = [AssetItemID(space: .personal, serverId: 1)]
        let proposed = [AssetItemID(space: .personal, serverId: 1), AssetItemID(space: .personal, serverId: 2)]
        #expect(PhotoGridController.identifiersChanged(current: current, proposed: proposed) == true)
    }

    @Test func identifiersChangedIsTrueWhenAPlaceholderResolvesToARealId() {
        // Mirrors a not-yet-loaded row (negative placeholder id) turning
        // into the real asset id once its page loads: same position, same
        // count, different identity, must still be treated as a change.
        let current = [AssetItemID(space: .personal, serverId: -1)]
        let proposed = [AssetItemID(space: .personal, serverId: 42)]
        #expect(PhotoGridController.identifiersChanged(current: current, proposed: proposed) == true)
    }

    @Test func identifiersChangedIsTrueWhenOrderDiffers() {
        let current = [AssetItemID(space: .personal, serverId: 1), AssetItemID(space: .personal, serverId: 2)]
        let proposed = [AssetItemID(space: .personal, serverId: 2), AssetItemID(space: .personal, serverId: 1)]
        #expect(PhotoGridController.identifiersChanged(current: current, proposed: proposed) == true)
    }

    @Test func identifiersChangedIsFalseForTwoEmptyLists() {
        #expect(PhotoGridController.identifiersChanged(current: [], proposed: []) == false)
    }

    /// End-to-end proof for the idle case: calling `applySnapshot()` again
    /// with nothing new loaded must not change the snapshot's item count or
    /// otherwise disturb it. This does not observe AppKit's internal
    /// reconfigure calls directly (that would need a real, on-screen
    /// collection view), but it does prove the guard is reachable and
    /// harmless through the real call path, matching how
    /// `prefetchItemsAt` invokes it repeatedly while idle.
    @Test func repeatedApplySnapshotWithNoNewDataIsIdempotent() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<50).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 50, total: 50, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 50)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view

        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 50)
        await controller.applySnapshot()
        #expect(controller.snapshotItemCount() == 50)

        // Repeated idle-tick calls, exactly like NSCollectionView firing
        // prefetchItemsAt over and over with nothing new to show.
        await controller.applySnapshot()
        await controller.applySnapshot()
        await controller.applySnapshot()
        #expect(controller.snapshotItemCount() == 50)
        #expect(controller.snapshotIsComplete == true)
    }

    // MARK: - PhotoCellView.needsReload (pure guard behind the cell flash fix)

    @Test func needsReloadIsFalseWhenSameKeyAlreadyDisplayed() {
        let key = ThumbKey(assetId: 1, size: .sm, cacheKey: "v1")
        #expect(PhotoCellView.needsReload(currentKey: key, requestedKey: key, hasImage: true) == false)
    }

    @Test func needsReloadIsTrueWhenNoImageIsDisplayedYet() {
        let key = ThumbKey(assetId: 1, size: .sm, cacheKey: "v1")
        // Same key, but nothing painted yet (still loading, or a previous
        // load failed): must still (re)attempt the load rather than no-op.
        #expect(PhotoCellView.needsReload(currentKey: key, requestedKey: key, hasImage: false) == true)
    }

    @Test func needsReloadIsTrueForADifferentAsset() {
        let current = ThumbKey(assetId: 1, size: .sm, cacheKey: "v1")
        let requested = ThumbKey(assetId: 2, size: .sm, cacheKey: "v1")
        #expect(PhotoCellView.needsReload(currentKey: current, requestedKey: requested, hasImage: true) == true)
    }

    @Test func needsReloadIsTrueWhenCacheKeyChangedForSameAsset() {
        let current = ThumbKey(assetId: 1, size: .sm, cacheKey: "v1")
        let requested = ThumbKey(assetId: 1, size: .sm, cacheKey: "v2")
        #expect(PhotoCellView.needsReload(currentKey: current, requestedKey: requested, hasImage: true) == true)
    }

    @Test func needsReloadIsTrueWhenNothingDisplayedYet() {
        let requested = ThumbKey(assetId: 1, size: .sm, cacheKey: "v1")
        #expect(PhotoCellView.needsReload(currentKey: nil, requestedKey: requested, hasImage: false) == true)
    }

    /// Re-configuring a cell for the exact asset it is already showing
    /// (the diffable-snapshot-reapply case) must not touch `thumbView` at
    /// all: no flash. This is the same-asset half of the flicker fix,
    /// proven through the real `configure` call path.
    @Test func configureForSameAssetDoesNotClearAlreadyDisplayedImage() async throws {
        let fake = FakePhotosCore()
        let path = writePNG(width: 300, height: 300)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResultByAssetId[5] = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let cell = PhotoCellView()
        _ = cell.view

        cell.configure(asset: asset(5), space: .personal, cache: cache)
        try await Task.sleep(for: .milliseconds(50))
        let firstImage = try #require(cell.displayedImage)

        // Reconfigure for the exact same asset, as a redundant diffable
        // snapshot re-apply would do. The image reference must be
        // untouched (same instance), proving thumbView.image was never
        // reset to nil in between.
        cell.configure(asset: asset(5), space: .personal, cache: cache)
        #expect(cell.displayedImage === firstImage)
    }

    // MARK: - Keyboard map integration (handleKey)

    private func keyEvent(_ keyCode: UInt16, command: Bool = false, shift: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    /// Builds a controller with `count` rows already resident and a
    /// snapshot already applied, matching how the real grid always looks
    /// by the time a key event can reach it (the grid is only ever in the
    /// view hierarchy once the crawl has completed and `applySnapshot()`
    /// has run at least once). `handleKey`'s row-count bound
    /// (`snapshotItemCount()`, not `dataSource.totalCount`) depends on
    /// this: skipping the snapshot apply here would silently test against
    /// a collection view with zero laid-out items regardless of `count`.
    private func makeController(count: Int) async -> (PhotoGridController, WindowedDataSource) {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<count).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: UInt64(count), total: UInt64(count), complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: max(count, 1))
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: max(count, 1))
        await controller.applySnapshot()
        return (controller, ds)
    }

    /// Any arrow key on a grid with no prior selection starts at index 0,
    /// matching Finder/Photos (an arrow press with nothing selected selects
    /// the first item regardless of direction).
    @Test func arrowKeyWithNoSelectionStartsAtFirstItem() async {
        let (controller, _) = await makeController(count: 10)

        var selectedIndex: Int?
        var openedIndex: Int?
        controller.onSelectionChanged = { selectedIndex = $0 }
        // Arrow keys must NEVER open the detail viewer, only move selection.
        controller.onOpenDetail = { openedIndex = $0 }

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == true)
        #expect(controller.selection.selected == [0])
        #expect(selectedIndex == 0)
        // Regression guard: pressing an arrow must not have opened detail.
        #expect(openedIndex == nil)
    }

    /// Regression for the bug where every arrow key opened the image: moving
    /// the selection with arrows reports through onSelectionChanged and never
    /// fires onOpenDetail.
    @Test func arrowKeysMoveSelectionWithoutOpeningDetail() async {
        let (controller, _) = await makeController(count: 10)
        controller.selection.click(4)

        var opened = false
        controller.onOpenDetail = { _ in opened = true }

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == true)
        #expect(controller.selection.selected == [5])
        #expect(opened == false)

        #expect(controller.handleKey(keyEvent(KeyCode.leftArrow)) == true)
        #expect(controller.selection.selected == [4])
        #expect(opened == false)
    }

    @Test func leftArrowMovesSelectionBackByOne() async {
        let (controller, _) = await makeController(count: 10)
        controller.selection.click(4)

        #expect(controller.handleKey(keyEvent(KeyCode.leftArrow)) == true)
        #expect(controller.selection.selected == [3])
    }

    @Test func rightArrowAtLastItemIsConsumedButDoesNotMove() async {
        let (controller, _) = await makeController(count: 5)
        controller.selection.click(4)

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == true)
        #expect(controller.selection.selected == [4])
    }

    @Test func cmdASelectsEveryItem() async {
        let (controller, _) = await makeController(count: 7)

        #expect(controller.handleKey(keyEvent(KeyCode.a, command: true)) == true)
        #expect(controller.selection.selected == Set(0..<7))
    }

    @Test func escapeClearsSelectionAndNotifiesCaller() async {
        let (controller, _) = await makeController(count: 5)
        controller.selection.click(2)

        var cleared = false
        controller.onClearSelection = { cleared = true }

        #expect(controller.handleKey(keyEvent(KeyCode.escape)) == true)
        #expect(controller.selection.isEmpty)
        #expect(cleared)
    }

    @Test func returnOpensDetailForCurrentSelection() async {
        let (controller, _) = await makeController(count: 5)
        controller.selection.click(3)

        var opened: Int?
        controller.onOpenDetail = { opened = $0 }

        #expect(controller.handleKey(keyEvent(KeyCode.returnKey)) == true)
        #expect(opened == 3)
    }

    @Test func spaceTogglesQuickLookForCurrentSelection() async {
        let (controller, _) = await makeController(count: 5)
        controller.selection.click(1)

        var toggled: Int?
        controller.onToggleQuickLook = { toggled = $0 }

        #expect(controller.handleKey(keyEvent(KeyCode.space)) == true)
        #expect(toggled == 1)
    }

    @Test func deleteRequestsWithCurrentSelectionCountAndNeverDeletes() async {
        let (controller, _) = await makeController(count: 5)
        controller.selection.click(0)
        controller.selection.toggle(2)

        var requestedCount: Int?
        controller.onDeleteRequested = { requestedCount = $0 }

        #expect(controller.handleKey(keyEvent(KeyCode.delete)) == true)
        #expect(requestedCount == 2)
        // Selection itself is untouched: Delete never mutates state on its
        // own, it only reports the count for the caller's confirm affordance.
        #expect(controller.selection.selected == [0, 2])
    }

    // MARK: - Shift+arrow selection extension

    /// The brief's exact scenario: from anchor 4, Shift+Right extends to
    /// {4,5}, a second Shift+Right extends to {4,5,6}, and it never opens
    /// the detail viewer (Shift+arrow is still a selection-only gesture,
    /// same as a plain arrow).
    @Test func shiftRightExtendsSelectionFromAnchor() async {
        let (controller, _) = await makeController(count: 10)
        controller.selection.click(4)

        var opened: Int?
        controller.onOpenDetail = { opened = $0 }

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) == true)
        #expect(controller.selection.selected == Set(4...5))
        #expect(controller.selection.anchor == 4)

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) == true)
        #expect(controller.selection.selected == Set(4...6))
        #expect(controller.selection.anchor == 4)
        #expect(opened == nil)
    }

    /// Shift+Left back across the anchor contracts, then flips the range to
    /// the other side, exactly like Finder/Photos shift-click.
    @Test func shiftLeftContractsThenFlipsAcrossTheAnchor() async {
        let (controller, _) = await makeController(count: 10)
        controller.selection.click(4)
        controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) // {4,5}
        controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) // {4,5,6}

        #expect(controller.handleKey(keyEvent(KeyCode.leftArrow, shift: true)) == true)
        #expect(controller.selection.selected == Set(4...5)) // contracts

        #expect(controller.handleKey(keyEvent(KeyCode.leftArrow, shift: true)) == true)
        #expect(controller.selection.selected == [4]) // back to just the anchor

        #expect(controller.handleKey(keyEvent(KeyCode.leftArrow, shift: true)) == true)
        #expect(controller.selection.selected == Set(3...4)) // flips past the anchor
        #expect(controller.selection.anchor == 4)
    }

    /// A plain arrow after an extended selection drops the range and starts
    /// a fresh single selection/anchor stepping from the anchor (not the
    /// far edge of the just-abandoned range), matching Finder/Photos:
    /// releasing Shift and pressing a plain arrow again moves the original
    /// single-item focus by one, it does not continue on from wherever the
    /// extended range happened to reach.
    @Test func plainArrowAfterExtendReplacesTheRangeWithASingleSelection() async {
        let (controller, _) = await makeController(count: 10)
        controller.selection.click(4)
        controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) // {4,5}
        controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) // {4,5,6}

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == true)
        #expect(controller.selection.selected == [5])
        #expect(controller.selection.anchor == 5)
    }

    /// Shift+arrow with nothing selected yet has no anchor to extend from,
    /// so it starts fresh at item 0 the same way a plain arrow would.
    @Test func shiftArrowWithNoSelectionStartsAtFirstItem() async {
        let (controller, _) = await makeController(count: 10)

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow, shift: true)) == true)
        #expect(controller.selection.selected == [0])
    }

    // MARK: - Drag-to-Finder export (canDragItemsAt / pasteboardWriterForItemAt)

    @Test func loadedRowCanBeDragged() async {
        let (controller, _) = await makeController(count: 5)
        let canDrag = controller.collectionView(
            controller.collectionView, canDragItemsAt: [IndexPath(item: 2, section: 0)])
        #expect(canDrag == true)
    }

    /// A not-yet-loaded placeholder row (index beyond what `loadWindow` has
    /// actually populated in `WindowedDataSource`) has no `unit_id`/
    /// `cache_key` to download from yet, so dragging it must be refused
    /// rather than starting a promise doomed to fail.
    @Test func unloadedPlaceholderRowCannotBeDragged() async {
        let fake = FakePhotosCore()
        // 5 rows exist server-side, but the page size is smaller than the
        // index under test, and no loadWindow call is made for it, so
        // index 4 stays an unresolved placeholder.
        fake.assets[.personal] = (0..<5).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 5, total: 5, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 2)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 2) // only rows 0-1 resident
        await controller.applySnapshot()

        let canDrag = controller.collectionView(
            controller.collectionView, canDragItemsAt: [IndexPath(item: 4, section: 0)])
        #expect(canDrag == false)
    }

    @Test func pasteboardWriterBuildsAFilePromiseProviderForALoadedRow() async {
        let (controller, _) = await makeController(count: 5)
        let writer = controller.collectionView(
            controller.collectionView, pasteboardWriterForItemAt: IndexPath(item: 1, section: 0))
        #expect(writer is NSFilePromiseProvider)
    }

    @Test func pasteboardWriterIsNilForAnUnloadedPlaceholderRow() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<5).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 5, total: 5, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 2)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 2)
        await controller.applySnapshot()

        let writer = controller.collectionView(
            controller.collectionView, pasteboardWriterForItemAt: IndexPath(item: 4, section: 0))
        #expect(writer == nil)
    }

    @Test func unrecognizedKeyIsNotConsumed() async {
        let (controller, _) = await makeController(count: 5)
        #expect(controller.handleKey(keyEvent(0xFF)) == false)
    }

    @Test func arrowKeyOnEmptyGridIsNotConsumed() async {
        let (controller, _) = await makeController(count: 0)
        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == false)
    }

    /// The exact crash this fix targets: calling `handleKey` before the
    /// collection view has ever had a snapshot applied (so its own laid-out
    /// item count is 0) must not crash even though `dataSource.totalCount`
    /// already reports rows. `scrollToItems`/`selectionIndexPaths` given an
    /// index path the collection view does not know about is an AppKit
    /// assertion failure, not a Swift-catchable error, so this proves the
    /// bound is against the applied snapshot, not the data source count.
    @Test func arrowKeyBeforeAnySnapshotAppliedDoesNotCrash() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 10)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        // Deliberately no `loadWindow`/`applySnapshot()` call: the
        // collection view's own item count is still 0 here even though
        // `dataSource.totalCount` is 10.

        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == false)
    }
}
