import Testing
import PhotosCore
@testable import MySynologyPhotos

/// Exercises `RecentlyDeletedModel`, the view-model behind the recycle-bin
/// view. Proves it loads the bin, restores/permanently-deletes exactly the
/// selected `recyclePath`s (in display order), and that the permanent-delete
/// (empty) path always raises its confirm before ever calling the core.
///
/// Every assertion is against `FakePhotosCore`'s recording counters, so these
/// prove the exact core calls (and the absence of calls) independent of any
/// SwiftUI presentation.
@MainActor
struct RecentlyDeletedModelTests {
    private func item(_ path: String, filename: String = "IMG.jpg", kind: MediaKind = .photo) -> RecycleItem {
        RecycleItem(recyclePath: path, filename: filename, deletedAt: 1_700_000_000, fileSize: 1_024, mediaKind: kind)
    }

    private func makeModel(_ items: [RecycleItem]) -> (RecentlyDeletedModel, FakePhotosCore) {
        let fake = FakePhotosCore()
        fake.recentlyDeleted = items
        let model = RecentlyDeletedModel(client: PhotosCoreClient(core: fake))
        return (model, fake)
    }

    // MARK: - Load

    @Test func loadPopulatesItemsAndMarksLoaded() async {
        let (model, fake) = makeModel([item("#recycle/a"), item("#recycle/b")])
        #expect(!model.hasLoaded)
        await model.load()
        #expect(model.hasLoaded)
        #expect(model.items.map(\.recyclePath) == ["#recycle/a", "#recycle/b"])
        #expect(fake.fetchRecentlyDeletedCallCount == 1)
    }

    @Test func loadFailureSurfacesErrorMessage() async {
        let (model, fake) = makeModel([])
        fake.fetchRecentlyDeletedResult = .failure(.Auth(message: "expired"))
        await model.load()
        #expect(model.errorMessage != nil)
    }

    @Test func loadDropsSelectionForVanishedPaths() async {
        let (model, _) = makeModel([item("#recycle/a"), item("#recycle/b")])
        await model.load()
        model.selection = ["#recycle/a", "#recycle/gone"]
        await model.load()
        #expect(model.selection == ["#recycle/a"])
    }

    // MARK: - Restore (no confirm)

    @Test func restoreCallsRestoreWithSelectedPathsInDisplayOrderThenReloads() async {
        let (model, fake) = makeModel([item("#recycle/a"), item("#recycle/b"), item("#recycle/c")])
        await model.load()
        // Selection set order is arbitrary; the call must use display order.
        model.selection = ["#recycle/c", "#recycle/a"]
        let fetchesBefore = fake.fetchRecentlyDeletedCallCount

        var libraryRefreshed = false
        await model.restoreSelected { libraryRefreshed = true }

        #expect(fake.restoreRecentlyDeletedCallCount == 1)
        #expect(fake.lastRestoreRecentlyDeletedPaths == ["#recycle/a", "#recycle/c"])
        #expect(model.selection.isEmpty)
        #expect(fake.fetchRecentlyDeletedCallCount > fetchesBefore, "restore should reload the bin")
        #expect(libraryRefreshed, "restore should ask the library to refresh")
    }

    @Test func restoreWithEmptySelectionMakesNoCall() async {
        let (model, fake) = makeModel([item("#recycle/a")])
        await model.load()
        await model.restoreSelected {}
        #expect(fake.restoreRecentlyDeletedCallCount == 0)
    }

    // MARK: - Permanent delete (gated, always confirmed)

    @Test func requestEmptyPresentsConfirmBeforeAnyCoreCall() async {
        let (model, fake) = makeModel([item("#recycle/a"), item("#recycle/b")])
        await model.load()
        model.selection = ["#recycle/a", "#recycle/b"]
        model.requestEmpty()
        #expect(model.isShowingEmptyConfirm)
        #expect(model.pendingEmptyCount == 2)
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
    }

    @Test func requestEmptyWithEmptySelectionShowsNoConfirm() async {
        let (model, fake) = makeModel([item("#recycle/a")])
        await model.load()
        model.requestEmpty()
        #expect(!model.isShowingEmptyConfirm)
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
    }

    @Test func cancelEmptyMakesZeroCoreCalls() async {
        let (model, fake) = makeModel([item("#recycle/a")])
        await model.load()
        model.selection = ["#recycle/a"]
        model.requestEmpty()
        model.cancelEmpty()
        #expect(!model.isShowingEmptyConfirm)
        #expect(model.pendingEmptyCount == 0)
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
    }

    @Test func emptyIsCalledOnlyOnConfirmWithSelectedPaths() async {
        let (model, fake) = makeModel([item("#recycle/a"), item("#recycle/b"), item("#recycle/c")])
        await model.load()
        model.selection = ["#recycle/b", "#recycle/a"]
        model.requestEmpty()
        // Still nothing deleted at the confirm stage.
        #expect(fake.emptyRecentlyDeletedCallCount == 0)

        await model.confirmEmpty()

        #expect(fake.emptyRecentlyDeletedCallCount == 1)
        #expect(fake.lastEmptyRecentlyDeletedPaths == ["#recycle/a", "#recycle/b"])
        #expect(model.selection.isEmpty)
        #expect(!model.isShowingEmptyConfirm)
    }

    /// The permanent-delete confirm must never be suppressed by any prior
    /// interaction: cancelling once (or confirming once) does not arm a
    /// "don't ask again" path. Every request raises the confirm afresh.
    @Test func permanentEmptyConfirmIsShownEveryTime() async {
        let (model, fake) = makeModel([item("#recycle/a"), item("#recycle/b"), item("#recycle/c")])
        await model.load()

        model.selection = ["#recycle/a"]
        model.requestEmpty()
        #expect(model.isShowingEmptyConfirm)
        model.cancelEmpty()
        #expect(!model.isShowingEmptyConfirm)

        // Second time: still raises the confirm, still no call before confirm.
        model.selection = ["#recycle/b"]
        model.requestEmpty()
        #expect(model.isShowingEmptyConfirm)
        #expect(fake.emptyRecentlyDeletedCallCount == 0)
        await model.confirmEmpty()
        #expect(fake.emptyRecentlyDeletedCallCount == 1)

        // Third time after a real empty: the confirm is raised yet again.
        model.selection = ["#recycle/c"]
        model.requestEmpty()
        #expect(model.isShowingEmptyConfirm)
    }
}
