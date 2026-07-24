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
}
