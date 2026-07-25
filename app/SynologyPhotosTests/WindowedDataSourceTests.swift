import Testing
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct WindowedDataSourceTests {
    private func asset(_ id: Int64) -> Asset {
        Asset(id: id, unitId: id + 10_000, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    @Test func loadsOnlyRequestedWindow() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        #expect(ds.totalCount == 500)
        #expect(ds.isReady == true)
        let window = await ds.loadWindow(offset: 100, limit: 50)
        #expect(window.count == 50)
        #expect(window.first?.id == 100)
        #expect(ds.item(at: 120)?.id == 120)
        #expect(ds.item(at: 400) == nil)
    }

    @Test func notReadyWhenCrawlIncomplete() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 3, total: 10, complete: false)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        #expect(ds.isReady == false)
    }

    @Test func setSpaceRequeries() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
        fake.assets[.shared] = (0..<3).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        fake.progressBySpace[.shared] = CrawlProgress(space: .shared, done: 3, total: 3, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        #expect(ds.totalCount == 10)
        await ds.setSpace(.shared)
        #expect(ds.totalCount == 3)
        #expect(ds.item(at: 9) == nil)
    }

    @Test func unloadedIndexTriggersFetchThenResolves() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()

        // Nothing loaded yet: item(at:) returns nil and schedules a page fetch.
        #expect(ds.item(at: 220) == nil)

        // Give the scheduled Task a chance to run and populate the cache.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(20))

        #expect(ds.item(at: 220)?.id == 220)
        // The whole page (200..<250) should have resolved, not just index 220.
        #expect(ds.item(at: 200)?.id == 200)
        #expect(ds.item(at: 249)?.id == 249)
    }

    @Test func loadedWindowsAreNotRefetched() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()

        await ds.loadWindow(offset: 0, limit: 50)

        // Mutate the backing store after the first load: if item(at:) ever
        // re-fetches an already-loaded page, these reads would observe the
        // new sentinel values instead of the originally cached ones.
        fake.assets[.personal] = (0..<500).map { _ in
            Asset(id: -1, unitId: -1, cacheKey: "stale", filename: "stale.jpg", mediaKind: .photo,
                  takenAt: nil, addedAt: nil, width: nil, height: nil,
                  fileSize: nil, space: .personal, serverVersion: nil)
        }

        for i in 0..<50 {
            #expect(ds.item(at: i)?.id == Int64(i))
        }

        // A page that was never loaded still reflects live core state,
        // proving the sentinel swap above would have been visible had the
        // already-loaded page above actually been re-fetched.
        let fresh = await ds.loadWindow(offset: 450, limit: 50)
        #expect(fresh.allSatisfy { $0.id == -1 })
    }

    @Test func inFlightPageIsNotRequestedTwice() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()

        // Querying several indices in the same unloaded page back-to-back
        // must only schedule one background load for that page.
        #expect(ds.item(at: 300) == nil)
        #expect(ds.item(at: 301) == nil)
        #expect(ds.item(at: 349) == nil)

        try? await Task.sleep(for: .milliseconds(20))

        #expect(ds.item(at: 300)?.id == 300)
        #expect(ds.item(at: 301)?.id == 301)
        #expect(ds.item(at: 349)?.id == 349)
    }

    // MARK: - Discovery collection windowing

    @Test func setCollectionLoadsFromFetchAssetsForNotFetchAssets() async {
        let fake = FakePhotosCore()
        let personId = DiscoveryCollection.person(id: 12279)
        fake.assetsForCollection[personId] = (0..<5).map { asset(Int64($0) + 1000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setCollection(personId)
        let window = await ds.loadWindow(offset: 0, limit: 50)
        #expect(window.count == 5)
        #expect(fake.fetchAssetsForCallCount == 1)
        #expect(fake.lastFetchAssetsForCollection == personId)
    }

    @Test func collectionWindowMarksReadyOnceAShortPageArrives() async {
        let fake = FakePhotosCore()
        let placeId = DiscoveryCollection.place(id: 756)
        fake.assetsForCollection[placeId] = (0..<5).map { asset(Int64($0) + 2000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setCollection(placeId)
        #expect(ds.isReady == false, "no page has loaded yet, so readiness is unknown")
        _ = await ds.loadWindow(offset: 0, limit: 50)
        #expect(ds.isReady == true, "a short page (5 rows for a 50-row ask) means this was the last page")
        #expect(ds.totalCount == 5)
    }

    @Test func collectionWindowStaysNotReadyOnAFullPage() async {
        let fake = FakePhotosCore()
        let tagId = DiscoveryCollection.tag(id: 5)
        fake.assetsForCollection[tagId] = (0..<50).map { asset(Int64($0) + 3000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setCollection(tagId)
        _ = await ds.loadWindow(offset: 0, limit: 50)
        #expect(ds.isReady == false, "a full page (50 rows for a 50-row ask) means there may be more")
        #expect(ds.totalCount == 50)
    }

    @Test func setCollectionResetsResidentFromAPriorSpace() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        let favorites = DiscoveryCollection.favorites
        fake.assetsForCollection[favorites] = (0..<3).map { asset(Int64($0) + 4000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        _ = await ds.loadWindow(offset: 0, limit: 50)
        #expect(ds.item(at: 0)?.id == 0)

        await ds.setCollection(favorites)
        #expect(ds.totalCount == 0, "switching source must reset totalCount until the collection's own first page loads")
        let window = await ds.loadWindow(offset: 0, limit: 50)
        #expect(window.map(\.id) == [4000, 4001, 4002], "must fetch from the collection, not the stale space cache")
    }

    @Test func setCollectionLoadsAlbumPhotosFromFetchAssetsFor() async {
        let fake = FakePhotosCore()
        let albumId = DiscoveryCollection.album(id: 42)
        fake.assetsForCollection[albumId] = (0..<7).map { asset(Int64($0) + 5000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setCollection(albumId)
        let window = await ds.loadWindow(offset: 0, limit: 50)
        #expect(window.count == 7)
        #expect(fake.fetchAssetsForCallCount == 1)
        #expect(fake.lastFetchAssetsForCollection == albumId)
    }

    @Test func discoverySourceDefaultsToPersonalSpaceForItemIdentity() async {
        let fake = FakePhotosCore()
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .shared, pageSize: 50)
        await ds.setCollection(.favorites)
        #expect(ds.space == .personal, "every discovery collection is personal-space-only")
    }

    // MARK: - Search windowing

    @Test func setSearchLoadsFromSearchAssetsNotFetchAssets() async {
        let fake = FakePhotosCore()
        fake.assetsForKeyword["food"] = (0..<5).map { asset(Int64($0) + 6000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setSearch("food")
        let window = await ds.loadWindow(offset: 0, limit: 50)
        #expect(window.count == 5)
        #expect(fake.searchAssetsCallCount == 1)
        #expect(fake.lastSearchKeyword == "food")
    }

    @Test func searchWindowMarksReadyOnceAShortPageArrives() async {
        let fake = FakePhotosCore()
        fake.assetsForKeyword["food"] = (0..<5).map { asset(Int64($0) + 6000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setSearch("food")
        #expect(ds.isReady == false, "no page has loaded yet, so readiness is unknown")
        _ = await ds.loadWindow(offset: 0, limit: 50)
        #expect(ds.isReady == true, "a short page (5 rows for a 50-row ask) means this was the last page")
        #expect(ds.totalCount == 5)
    }

    @Test func searchWindowReturnsCleanEmptyOnNoMatch() async {
        let fake = FakePhotosCore()
        // No entry for this keyword at all: the fake's default (an empty
        // array) mirrors the core's own clean-empty-list behavior on a
        // keyword that matches nothing.
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.setSearch("zzzznosuchthing123")
        let window = await ds.loadWindow(offset: 0, limit: 50)
        #expect(window.isEmpty)
        #expect(ds.totalCount == 0)
        #expect(ds.isReady == true, "an empty result is itself a short page and must resolve ready, not hang loading")
    }

    @Test func setSearchResetsResidentFromAPriorSpace() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        fake.assetsForKeyword["food"] = (0..<3).map { asset(Int64($0) + 7000) }
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        _ = await ds.loadWindow(offset: 0, limit: 50)
        #expect(ds.item(at: 0)?.id == 0)

        await ds.setSearch("food")
        #expect(ds.totalCount == 0, "switching source must reset totalCount until the search's own first page loads")
        let window = await ds.loadWindow(offset: 0, limit: 50)
        #expect(window.map(\.id) == [7000, 7001, 7002], "must fetch from the search, not the stale space cache")
    }

    @Test func searchSourceDefaultsToPersonalSpaceForItemIdentity() async {
        let fake = FakePhotosCore()
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .shared, pageSize: 50)
        await ds.setSearch("food")
        #expect(ds.space == .personal, "the search API is personal-space-only")
    }
}
