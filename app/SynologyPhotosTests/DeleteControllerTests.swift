import Testing
import PhotosCore
@testable import SynologyPhotos

/// Exercises the hybrid safe-delete contract on `DeleteController`, the piece
/// that guarantees a confirm is always shown before any mutation and that the
/// raw destructive verb is reachable only through its own dedicated confirm.
///
/// Every assertion is against `FakePhotosCore`'s recording counters, so these
/// prove the exact core calls (and, crucially, the absence of calls) each step
/// makes, independent of any SwiftUI presentation.
@MainActor
struct DeleteControllerTests {
    private func makeController() -> (DeleteController, FakePhotosCore) {
        let fake = FakePhotosCore()
        let controller = DeleteController(client: PhotosCoreClient(core: fake))
        return (controller, fake)
    }

    // MARK: - Everyday delete-to-trash

    @Test func requestDeletePresentsConfirmBeforeAnyCoreCall() {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [1, 2, 3])
        #expect(controller.isShowingTrashConfirm)
        #expect(controller.pendingTrashCount == 3)
        // The confirm must be up with nothing yet touched on the core.
        #expect(fake.deleteToTrashCallCount == 0)
        #expect(fake.permanentlyDeleteCallCount == 0)
    }

    @Test func requestDeleteWithEmptySelectionShowsNoConfirm() {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [])
        #expect(!controller.isShowingTrashConfirm)
        #expect(fake.deleteToTrashCallCount == 0)
    }

    @Test func cancelDeleteMakesZeroCoreCalls() async {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [7, 8])
        controller.cancelDelete()
        #expect(!controller.isShowingTrashConfirm)
        #expect(controller.pendingTrashCount == 0)
        #expect(fake.deleteToTrashCallCount == 0)
        #expect(fake.permanentlyDeleteCallCount == 0)
    }

    @Test func confirmDeleteCallsDeleteToTrashWithExactlyTheSelectedIds() async {
        let (controller, fake) = makeController()
        controller.requestDelete(ids: [10, 20, 30])

        var didRefresh = false
        await controller.confirmDelete(space: .personal) { didRefresh = true }

        #expect(fake.deleteToTrashCallCount == 1)
        #expect(fake.lastDeleteToTrashIds == [10, 20, 30])
        #expect(fake.lastDeleteToTrashSpace == .personal)
        // Everyday delete NEVER touches the raw destructive verb.
        #expect(fake.permanentlyDeleteCallCount == 0)
        // Refresh runs only after a successful move, and the confirm clears.
        #expect(didRefresh)
        #expect(!controller.isShowingTrashConfirm)
        #expect(controller.pendingTrashCount == 0)
    }

    @Test func confirmDeleteFailureSurfacesErrorAndSkipsRefresh() async {
        let (controller, fake) = makeController()
        fake.deleteToTrashResult = .failure(.Network(message: "dropped"))
        controller.requestDelete(ids: [1])

        var didRefresh = false
        await controller.confirmDelete(space: .personal) { didRefresh = true }

        #expect(fake.deleteToTrashCallCount == 1)
        #expect(!didRefresh)
        #expect(controller.errorMessage != nil)
    }

    // MARK: - Restore

    @Test func restoreCallsRestoreFromTrashWithTheSelectedIds() async {
        let (controller, fake) = makeController()

        var didRefresh = false
        await controller.restore(space: .personal, ids: [4, 5]) { didRefresh = true }

        #expect(fake.restoreFromTrashCallCount == 1)
        #expect(fake.lastRestoreFromTrashIds == [4, 5])
        #expect(fake.lastRestoreFromTrashSpace == .personal)
        #expect(didRefresh)
        // Restore is not a destructive path.
        #expect(fake.permanentlyDeleteCallCount == 0)
        #expect(fake.deleteToTrashCallCount == 0)
    }

    @Test func restoreWithEmptySelectionMakesNoCall() async {
        let (controller, fake) = makeController()
        await controller.restore(space: .personal, ids: []) {}
        #expect(fake.restoreFromTrashCallCount == 0)
    }

    // MARK: - Permanent delete (gated, always confirmed)

    @Test func requestPermanentDeletePresentsItsOwnConfirmBeforeAnyCoreCall() {
        let (controller, fake) = makeController()
        controller.requestPermanentDelete(ids: [1, 2])
        #expect(controller.isShowingPermanentConfirm)
        #expect(controller.pendingPermanentCount == 2)
        #expect(fake.permanentlyDeleteCallCount == 0)
    }

    @Test func cancelPermanentDeleteMakesZeroCoreCalls() {
        let (controller, fake) = makeController()
        controller.requestPermanentDelete(ids: [9])
        controller.cancelPermanentDelete()
        #expect(!controller.isShowingPermanentConfirm)
        #expect(controller.pendingPermanentCount == 0)
        #expect(fake.permanentlyDeleteCallCount == 0)
    }

    @Test func permanentlyDeleteIsCalledOnlyOnConfirm() async {
        let (controller, fake) = makeController()
        controller.requestPermanentDelete(ids: [100, 200])
        // Still nothing deleted at the confirm stage.
        #expect(fake.permanentlyDeleteCallCount == 0)

        var didRefresh = false
        await controller.confirmPermanentDelete(space: .personal) { didRefresh = true }

        #expect(fake.permanentlyDeleteCallCount == 1)
        #expect(fake.lastPermanentlyDeleteIds == [100, 200])
        #expect(fake.lastPermanentlyDeleteSpace == .personal)
        #expect(didRefresh)
        #expect(!controller.isShowingPermanentConfirm)
    }

    /// The permanent-delete confirm must never be suppressed by any prior
    /// interaction: cancelling once (or confirming once) does not arm a
    /// "don't ask again" path. Every request raises the confirm afresh.
    @Test func permanentDeleteConfirmIsShownEveryTime() async {
        let (controller, fake) = makeController()

        controller.requestPermanentDelete(ids: [1])
        #expect(controller.isShowingPermanentConfirm)
        controller.cancelPermanentDelete()
        #expect(!controller.isShowingPermanentConfirm)

        // Second time: still raises the confirm, still no call before confirm.
        controller.requestPermanentDelete(ids: [2])
        #expect(controller.isShowingPermanentConfirm)
        #expect(fake.permanentlyDeleteCallCount == 0)
        await controller.confirmPermanentDelete(space: .personal) {}
        #expect(fake.permanentlyDeleteCallCount == 1)

        // Third time after a real delete: the confirm is raised yet again.
        controller.requestPermanentDelete(ids: [3])
        #expect(controller.isShowingPermanentConfirm)
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
