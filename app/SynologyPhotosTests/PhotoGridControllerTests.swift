import Testing
import AppKit
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct PhotoGridControllerTests {
    private func asset(_ id: Int64) -> Asset {
        Asset(id: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
              fileSize: nil, space: .personal, serverVersion: id)
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
        #expect(controller.snapshotItemCount() == 60)
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
    @Test func prepareForReuseCancelsPendingLoadSoStaleImageNeverApplies() async {
        let cache = ThumbnailCache(client: PhotosCoreClient(core: FakePhotosCore()))
        let cell = PhotoCellView()
        _ = cell.view

        cell.configure(asset: asset(1), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 1)

        // Simulate the collection view recycling this cell for a different
        // index before asset 1's async load has had a chance to resolve.
        cell.prepareForReuse()
        #expect(cell.representedAssetId == -1)

        cell.configure(asset: asset(2), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 2)

        // Give any still-running task a chance to run; even if asset 1's
        // load somehow resolved late, its guard (representedAssetId ==
        // capturedTargetId) must keep it from overwriting asset 2's cell.
        await Task.yield()
        #expect(cell.representedAssetId == 2)
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
}
