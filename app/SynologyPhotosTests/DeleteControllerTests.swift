import Testing
import PhotosCore
@testable import SynologyPhotos

/// Exercises the everyday delete contract on `DeleteController`: a confirm is
/// always shown before any mutation, and confirming calls the REAL delete
/// (`deleteAssets`) with exactly the selected ids. Permanent deletion no
/// longer lives here at all (it moved to `RecentlyDeletedModel`, keyed by
/// recycle path), so there is nothing on this controller that can bypass the
/// recycle bin.
///
/// Every assertion is against `FakePhotosCore`'s recording counters, so these
/// prove the exact core calls (and, crucially, the absence of calls) each
/// step makes, independent of any SwiftUI presentation.
@MainActor
struct DeleteControllerTests {
    private func makeController() -> (DeleteController, FakePhotosCore) {
        let fake = FakePhotosCore()
        let controller = DeleteController(client: PhotosCoreClient(core: fake))
        return (controller, fake)
    }

    @Test func requestDeletePresentsConfirmBeforeAnyCoreCall() {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [1, 2, 3])
        #expect(controller.isShowingDeleteConfirm)
        #expect(controller.pendingDeleteCount == 3)
        // The confirm must be up with nothing yet deleted.
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func requestDeleteWithEmptySelectionShowsNoConfirm() {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [])
        #expect(!controller.isShowingDeleteConfirm)
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func cancelDeleteMakesZeroCoreCalls() {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [7, 8])
        controller.cancelDelete()
        #expect(!controller.isShowingDeleteConfirm)
        #expect(controller.pendingDeleteCount == 0)
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func confirmDeleteCallsDeleteAssetsWithExactlyTheSelectedIds() async {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [10, 20, 30])

        var didRefresh = false
        await controller.confirmDelete(space: .personal) { didRefresh = true }

        #expect(fake.deleteAssetsCallCount == 1)
        #expect(fake.lastDeleteAssetsIds == [10, 20, 30])
        #expect(fake.lastDeleteAssetsSpace == .personal)
        // Refresh runs only after a successful delete, and the confirm clears.
        #expect(didRefresh)
        #expect(!controller.isShowingDeleteConfirm)
        #expect(controller.pendingDeleteCount == 0)
    }

    @Test func confirmDeleteFailureSurfacesErrorAndSkipsRefresh() async {
        let (controller, fake) = makeController()
        fake.deleteAssetsResult = .failure(.Network(message: "dropped"))
        controller.requestDelete(ids: [1])

        var didRefresh = false
        await controller.confirmDelete(space: .personal) { didRefresh = true }

        #expect(fake.deleteAssetsCallCount == 1)
        #expect(!didRefresh)
        #expect(controller.errorMessage != nil)
    }

    /// The full-photo detail viewer wires its Delete button / key to the SAME
    /// controller with the shown asset's id (see `LibraryView.detailViewer`'s
    /// `onDelete`). This proves that path: a single-asset request raises the
    /// confirm and, on confirm, deletes exactly that asset, never touching the
    /// core before the confirm.
    @Test func detailViewerDeleteRunsTheSameConfirmedDeleteFlowForTheShownAsset() async {
        let (controller, fake) = makeController()
        let shown = asset(4242)

        // Mirror the detail viewer's onDelete closure exactly.
        controller.requestDelete(ids: [shown.id])
        #expect(controller.isShowingDeleteConfirm)
        #expect(controller.pendingDeleteCount == 1)
        #expect(fake.deleteAssetsCallCount == 0)

        var didClose = false
        await controller.confirmDelete(space: .personal) { didClose = true }

        #expect(fake.deleteAssetsCallCount == 1)
        #expect(fake.lastDeleteAssetsIds == [4242])
        #expect(didClose)
        #expect(!controller.isShowingDeleteConfirm)
    }

    /// End-to-end guard on the "exactly the selected ids" claim: a grid
    /// controller resolves its loaded selection to server ids, and those are
    /// what the delete confirm carries. Proves the resolution the real delete
    /// path relies on, using a controller backed by a windowed data source.
    /// Minimal asset fixture with an explicit id, kept as its own function
    /// (rather than an inline closure literal) so the type-checker resolves it
    /// quickly instead of choking on a complex expression.
    private func asset(_ id: Int64) -> Asset {
        Asset(id: id, unitId: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000 + id, addedAt: nil, width: 10, height: 10,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    @Test func selectedAssetIdsResolvesLoadedSelectionToServerIds() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = [100, 101, 102, 103, 104].map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 5, total: 5, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 10)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 10)
        await controller.applySnapshot()

        controller.selection.click(0)
        controller.selection.shiftClick(2)   // selects rows 0,1,2
        #expect(controller.selectedAssetIds() == [100, 101, 102])
    }
}
