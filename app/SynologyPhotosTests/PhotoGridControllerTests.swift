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
        let controller = PhotoGridController(dataSource: ds, cache: cache)
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
        let controller = PhotoGridController(dataSource: ds, cache: cache)
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
        let controller = PhotoGridController(dataSource: ds, cache: cache)
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
        let controller = PhotoGridController(dataSource: ds, cache: cache)
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
        let controller = PhotoGridController(dataSource: ds, cache: cache)

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
        let controller = PhotoGridController(dataSource: ds, cache: cache)

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
}
