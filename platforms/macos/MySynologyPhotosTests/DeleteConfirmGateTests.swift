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
        await controller.requestDelete(ids: [1, 2])
        controller.cancelDelete()
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func confirmingTwiceDeletesOnce() async {
        let (controller, fake) = makeDelete()
        await controller.requestDelete(ids: [1])
        await controller.confirmDelete(space: .personal) {}
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 1)
    }

    @Test func everydayDeleteWordingSaysRecoverable() {
        #expect(DeleteController.confirmMessage(count: 1, status: .enabled).contains("can be restored"))
        #expect(DeleteController.confirmMessage(count: 5, status: .enabled).contains("5 items"))
        #expect(DeleteController.confirmMessage(count: 5, status: .enabled).contains("can be restored"))
        #expect(DeleteController.confirmTitle(count: 1) == "Delete Photo")
        #expect(DeleteController.confirmTitle(count: 2) == "Delete Photos")
    }

    // MARK: - Recycle bin status gate

    @Test func disabledRecycleBinRaisesNoConfirmAndNeverDeletes() async {
        let (controller, fake) = makeDelete()
        fake.recycleBinStatusResult = .success(.disabled)
        await controller.requestDelete(ids: [1, 2], filenames: ["a.jpg", "b.jpg"])
        #expect(!controller.isShowingDeleteConfirm)
        #expect(controller.isShowingRecycleBinOff)
        #expect(controller.pendingDeleteCount == 0)
        // Even a stray confirm (e.g. a stale button press) must not delete.
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func disabledRecycleBinClearsAnEarlierPendingRequest() async {
        // An earlier request raised a confirm while the bin was on; the user
        // then turns it off in DSM and asks again before confirming. The
        // stale pending ids must not survive into a later confirm.
        let (controller, fake) = makeDelete()
        await controller.requestDelete(ids: [1])
        fake.recycleBinStatusResult = .success(.disabled)
        await controller.requestDelete(ids: [2])
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func enabledRecycleBinRaisesTheRecoverableConfirmAndDeletesOnConfirm() async {
        let (controller, fake) = makeDelete()
        fake.recycleBinStatusResult = .success(.enabled)
        await controller.requestDelete(ids: [4])
        #expect(controller.isShowingDeleteConfirm)
        #expect(!controller.isShowingRecycleBinOff)
        #expect(controller.pendingRecycleBinStatus == .enabled)
        #expect(fake.deleteAssetsCallCount == 0)
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 1)
        #expect(fake.lastDeleteAssetsIds == [4])
    }

    @Test func unknownRecycleBinWarnsAndDeletesOnlyOnConfirm() async {
        let (controller, fake) = makeDelete()
        fake.recycleBinStatusResult = .success(.unknown)
        await controller.requestDelete(ids: [5, 6])
        #expect(controller.isShowingDeleteConfirm)
        #expect(controller.pendingRecycleBinStatus == .unknown)
        #expect(fake.deleteAssetsCallCount == 0)
        let message = DeleteController.confirmMessage(
            count: controller.pendingDeleteCount, status: controller.pendingRecycleBinStatus)
        #expect(message.contains("could not confirm"))
        #expect(message.contains("permanent"))
        #expect(!message.contains("can be restored"))
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 1)
        #expect(fake.lastDeleteAssetsIds == [5, 6])
    }

    @Test func unknownRecycleBinCancelNeverDeletes() async {
        let (controller, fake) = makeDelete()
        fake.recycleBinStatusResult = .success(.unknown)
        await controller.requestDelete(ids: [5])
        controller.cancelDelete()
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func recycleBinStatusIsFetchedOnEveryRequest() async {
        let (controller, fake) = makeDelete()
        await controller.requestDelete(ids: [1])
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.recycleBinStatusCallCount == 1)
        // The user turns the bin off in DSM between two deletes: the second
        // request must see it, not a remembered "enabled".
        fake.recycleBinStatusResult = .success(.disabled)
        await controller.requestDelete(ids: [2])
        #expect(fake.recycleBinStatusCallCount == 2)
        #expect(!controller.isShowingDeleteConfirm)
        #expect(controller.isShowingRecycleBinOff)
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 1)
    }

    @Test func recycleBinStatusErrorRaisesNoConfirmAndSurfacesTheError() async {
        let (controller, fake) = makeDelete()
        fake.recycleBinStatusResult = .failure(.Auth(message: "expired"))
        await controller.requestDelete(ids: [1])
        #expect(!controller.isShowingDeleteConfirm)
        #expect(controller.errorMessage != nil)
        await controller.confirmDelete(space: .personal) {}
        #expect(fake.deleteAssetsCallCount == 0)
    }

    @Test func recycleBinWordingIsPinned() {
        #expect(DeleteController.confirmMessage(count: 1, status: .enabled)
            == "Delete 1 item? It moves to your Synology recycle bin and can be restored.")
        #expect(DeleteController.confirmMessage(count: 3, status: .unknown)
            == "Delete 3 items? The app could not confirm that your Synology recycle bin is on. "
                + "If it is off, this delete is permanent and cannot be undone.")
        // A slip that let `.disabled` reach the confirm must only over-warn.
        #expect(!DeleteController.confirmMessage(count: 1, status: .disabled).contains("can be restored"))
        #expect(DeleteController.recycleBinOffMessage.contains("permanent"))
        #expect(DeleteController.recycleBinOffMessage.contains("will not delete"))
        #expect(DeleteController.recycleBinOffMessage.contains("Enable Recycle Bin"))
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
