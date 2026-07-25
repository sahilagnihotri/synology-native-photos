import Testing
import AppKit
import PhotosCore
@testable import SynologyPhotos

/// End-to-end proof that the library grid sections by day: the controller
/// builds one collection-view section per histogram bucket, keeps the total
/// item count and cross-section selection/navigation correct, and leaves the
/// flat discovery/search grids unsectioned.
@MainActor
struct PhotoGridSectioningTests {
    private func asset(_ id: Int64, takenAt: Int64?) -> Asset {
        Asset(id: id, unitId: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: takenAt, addedAt: nil, width: 100, height: 100,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    private func videoAsset(_ id: Int64, takenAt: Int64?) -> Asset {
        Asset(id: id, unitId: id, cacheKey: "v", filename: "\(id).mov", mediaKind: .video,
              takenAt: takenAt, addedAt: nil, width: 1920, height: 1080,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    private func keyEvent(_ keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode)!
    }

    /// Three calendar days, provided newest-first so the fake's array order
    /// matches the histogram's newest-first order (making per-section item
    /// identity line up): day A has 2, day B has 3, day C has 1.
    private func threeDayFixture() -> [Asset] {
        let dayA: Int64 = 1_480_032_000        // 2016-11-25 UTC
        let dayB: Int64 = dayA - 86_400         // 2016-11-24
        let dayC: Int64 = dayA - 2 * 86_400     // 2016-11-23
        return [
            asset(10, takenAt: dayA + 500),
            asset(11, takenAt: dayA + 100),
            asset(20, takenAt: dayB + 700),
            asset(21, takenAt: dayB + 300),
            asset(22, takenAt: dayB + 100),
            asset(30, takenAt: dayC + 42),
        ]
    }

    private func makeSpaceController(_ assets: [Asset]) async -> (PhotoGridController, WindowedDataSource) {
        let fake = FakePhotosCore()
        fake.assets[.personal] = assets
        fake.progressBySpace[.personal] = CrawlProgress(
            space: .personal, done: UInt64(assets.count), total: UInt64(assets.count), complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: max(assets.count, 1))
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: max(assets.count, 1))
        await controller.applySnapshot()
        return (controller, ds)
    }

    @Test func buildsOneSectionPerDayWithCorrectCounts() async {
        let (controller, ds) = await makeSpaceController(threeDayFixture())
        #expect(ds.dateSections?.sections.count == 3)
        #expect(ds.dateSections?.sections.map(\.count) == [2, 3, 1])
        #expect(controller.collectionView.numberOfSections == 3)
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 2)
        #expect(controller.collectionView.numberOfItems(inSection: 1) == 3)
        #expect(controller.collectionView.numberOfItems(inSection: 2) == 1)
        // Total across sections still equals the whole library.
        #expect(controller.snapshotItemCount() == 6)
    }

    @Test func undatedRowsFormATrailingUnknownDateSection() async {
        var assets = threeDayFixture()
        assets.append(asset(40, takenAt: nil))
        assets.append(asset(41, takenAt: nil))
        let (controller, ds) = await makeSpaceController(assets)
        // 3 dated days + 1 Unknown Date bucket.
        #expect(ds.dateSections?.sections.count == 4)
        #expect(ds.dateSections?.sections.last?.dayStart == 0)
        #expect(ds.dateSections?.sections.last?.count == 2)
        #expect(controller.collectionView.numberOfSections == 4)
        #expect(controller.snapshotItemCount() == 8)
    }

    /// Selecting a range that straddles the day A -> day B boundary resolves to
    /// the correct assets on both sides, proving the (section, item) -> absolute
    /// mapping is wired through selection.
    @Test func selectionAcrossSectionBoundaryResolvesTheRightAssets() async {
        let (controller, _) = await makeSpaceController(threeDayFixture())
        controller.selection.click(1)      // last item of day A (absolute 1)
        controller.selection.shiftClick(2) // first item of day B (absolute 2)
        #expect(controller.selectedAssetIds() == [11, 20])
    }

    /// Right arrow steps by one absolute index, crossing cleanly from the end
    /// of one day section into the start of the next (left/right nav does not
    /// depend on row geometry, so this is exact regardless of layout width).
    @Test func rightArrowCrossesFromEndOfOneDayIntoTheNext() async {
        let (controller, _) = await makeSpaceController(threeDayFixture())
        controller.selection.click(1) // last item of day A
        #expect(controller.handleKey(keyEvent(KeyCode.rightArrow)) == true)
        #expect(controller.selection.selected == [2]) // first item of day B
    }

    /// Select-all spans every section, and the resolved ids cover all six rows
    /// in grid order across the section boundaries.
    @Test func selectAllSpansEverySection() async {
        let (controller, _) = await makeSpaceController(threeDayFixture())
        controller.selection.selectAll(count: controller.snapshotItemCount())
        #expect(controller.selectedAssetIds() == [10, 11, 20, 21, 22, 30])
    }

    /// A discovery collection grid is never date-sectioned: it stays a single
    /// flat section, exactly as before this feature.
    @Test func discoveryCollectionGridStaysFlat() async {
        let fake = FakePhotosCore()
        let personId = DiscoveryCollection.person(id: 1)
        fake.assetsForCollection[personId] = (0..<3).map { asset(Int64($0), takenAt: 1_480_032_000 + Int64($0)) }
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 50)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache, client: client)
        _ = controller.view
        await ds.setCollection(personId)
        _ = await ds.loadWindow(offset: 0, limit: 50)
        await controller.applySnapshot()
        #expect(ds.dateSections == nil)
        #expect(controller.collectionView.numberOfSections == 1)
        #expect(controller.snapshotItemCount() == 3)
    }

    // MARK: - Quick Filter reconciliation (sectioned library <-> flat filter)

    /// A library fixture spanning two calendar days, each mixing photos and
    /// videos, so a Videos-only Quick Filter produces a strictly smaller,
    /// differently-shaped result (2 rows) than the full library (5 rows across
    /// 2 day sections). Newest-first so the fake's array order matches the
    /// histogram's newest-first order.
    private func mixedMediaFixture() -> [Asset] {
        let dayA: Int64 = 1_480_032_000    // 2016-11-25 UTC
        let dayB: Int64 = dayA - 86_400     // 2016-11-24
        return [
            asset(10, takenAt: dayA + 500),
            videoAsset(11, takenAt: dayA + 100),
            asset(20, takenAt: dayB + 700),
            asset(21, takenAt: dayB + 300),
            videoAsset(22, takenAt: dayB + 100),
        ]
    }

    /// The reported bug: applying a Quick Filter (File Type = Videos) over the
    /// date-sectioned library must switch the grid to the flat, videos-only
    /// result. Before the fix the collection view kept showing the old
    /// date-sectioned library (2 sections, 5 items) instead of the single flat
    /// section of 2 videos, because the section geometry was not reconciled
    /// when the source flipped from `.space` (dateSections set) to `.filter`
    /// (dateSections nil).
    @Test func applyingVideoFilterSwitchesGridToFlatVideosOnly() async {
        let (controller, ds) = await makeSpaceController(mixedMediaFixture())
        // Precondition: the plain library is date-sectioned (2 days, 5 items).
        #expect(controller.collectionView.numberOfSections == 2)
        #expect(controller.snapshotItemCount() == 5)

        // Apply the Videos Quick Filter exactly as `RootView.applyQuickFilter`
        // does: switch the source, load the first window, re-apply.
        controller.clearSelection()
        await ds.setFilter(space: .personal, query: FilterQuery(mediaKind: .video))
        await ds.loadWindow(offset: 0, limit: 50)
        await controller.applySnapshot()

        // The grid must now be a single flat section of exactly the two videos,
        // with none of the old day sections or photo rows lingering.
        #expect(ds.dateSections == nil)
        #expect(controller.collectionView.numberOfSections == 1)
        #expect(controller.collectionView.numberOfItems(inSection: 0) == 2)
        #expect(controller.snapshotItemCount() == 2)
        controller.selection.selectAll(count: controller.snapshotItemCount())
        #expect(controller.selectedAssetIds() == [11, 22])
    }

    /// Clearing the filter restores the plain, date-sectioned library: the grid
    /// goes back from the flat 2-video result to the 2 day sections / 5 rows.
    /// Proves the reconciliation is symmetric (flat -> sectioned as well as
    /// sectioned -> flat).
    @Test func clearingFilterRestoresTheSectionedLibrary() async {
        let (controller, ds) = await makeSpaceController(mixedMediaFixture())

        await ds.setFilter(space: .personal, query: FilterQuery(mediaKind: .video))
        await ds.loadWindow(offset: 0, limit: 50)
        await controller.applySnapshot()
        #expect(controller.collectionView.numberOfSections == 1)
        #expect(controller.snapshotItemCount() == 2)

        // Clear back to the space source, as `RootView.clearQuickFilter` does.
        controller.clearSelection()
        await ds.setSpace(.personal)
        await ds.loadWindow(offset: 0, limit: 50)
        await controller.applySnapshot()

        #expect(ds.dateSections?.sections.count == 2)
        #expect(controller.collectionView.numberOfSections == 2)
        #expect(controller.snapshotItemCount() == 5)
        controller.selection.selectAll(count: controller.snapshotItemCount())
        #expect(controller.selectedAssetIds() == [10, 11, 20, 21, 22])
    }
}
