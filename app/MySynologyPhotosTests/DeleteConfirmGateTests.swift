import Testing
import PhotosCore
@testable import MySynologyPhotos

/// Gap-filling tests for the delete confirm gates: wording, a confirm with no
/// pending request, a confirm after cancel, and a double confirm. Core calls
/// are counted on `FakePhotosCore`, so nothing here can reach a NAS.
@MainActor
struct DeleteConfirmGateTests {
    private func makeDelete() -> (DeleteController, FakePhotosCore) {
        let fake = FakePhotosCore()
        return (DeleteController(client: PhotosCoreClient(core: fake)), fake)
    }

    private func makeBin() async -> (RecentlyDeletedModel, FakePhotosCore) {
        let fake = FakePhotosCore()
        fake.recentlyDeleted = [
            RecycleItem(recyclePath: "#recycle/a", filename: "a.jpg", deletedAt: 1, fileSize: 1, mediaKind: .photo),
        ]
        let model = RecentlyDeletedModel(client: PhotosCoreClient(core: fake))
        await model.load()
        model.selection = ["#recycle/a"]
        return (model, fake)
    }

    // MARK: - Everyday delete

    @Test func confirmDeleteWithoutARequestCallsNothing() async {
        let (controller, fake) = makeDelete()
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func confirmDeleteAfterCancelCallsNothing() async {
        let (controller, fake) = makeDelete()
        controller.requestDelete(ids: [1, 2])
        controller.cancelDelete()
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func confirmingTwiceDeletesOnce() async {
        let (controller, fake) = makeDelete()
        controller.requestDelete(ids: [1])
        await controller.confirmDelete(space: .personal) {}
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 1)
    }

    @Test func everydayDeleteWordingSaysRecoverable() {
        #expect(DeleteController.confirmMessage(count: 1).contains("can be restored"))
        #expect(DeleteController.confirmMessage(count: 5).contains("5 items"))
        #expect(DeleteController.confirmMessage(count: 5).contains("can be restored"))
        #expect(DeleteController.confirmTitle(count: 1) == "Delete Photo")
        #expect(DeleteController.confirmTitle(count: 2) == "Delete Photos")
    }

    // MARK: - Permanent delete

    @Test func confirmEmptyWithoutARequestCallsNothing() async {
        let (model, fake) = await makeBin()
        await model.confirmEmpty()
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
    }

    @Test func confirmEmptyAfterCancelCallsNothing() async {
        let (model, fake) = await makeBin()
        model.requestEmpty()
        model.cancelEmpty()
        await model.confirmEmpty()
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
    }

    @Test func confirmingEmptyTwiceDeletesOnce() async {
        let (model, fake) = await makeBin()
        model.requestEmpty()
        await model.confirmEmpty()
        await model.confirmEmpty()
        #expect(fake.emptyRecentlyDeletedCallCount == 1)
    }

    @Test func restoreNeverCallsPermanentDelete() async {
        let (model, fake) = await makeBin()
        await model.restoreSelected()
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
    }

    @Test func permanentDeleteWordingSaysItCannotBeUndone() {
        #expect(RecentlyDeletedModel.emptyConfirmMessage(count: 1).contains("cannot be undone"))
        #expect(RecentlyDeletedModel.emptyConfirmMessage(count: 3).contains("3 items"))
        #expect(RecentlyDeletedModel.emptyConfirmMessage(count: 3).contains("cannot be undone"))
    }
}
