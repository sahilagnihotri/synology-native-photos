import Testing
import PhotosCore
@testable import MySynologyPhotos

@MainActor
struct DiscoveryTilesModelTests {
    @Test func loadPopulatesTilesAndRoutesToTilesOnSuccess() async {
        let fake = FakePhotosCore()
        fake.peopleResult = .success([
            Person(id: 1, name: "", itemCount: 3, coverUnitId: 100, show: true),
            Person(id: 2, name: "Sahil", itemCount: 7, coverUnitId: nil, show: true),
        ])
        let model = DiscoveryTilesModel(client: PhotosCoreClient(core: fake), kind: .people)
        await model.load()
        #expect(model.route == .tiles)
        #expect(model.tiles.count == 2)
        #expect(fake.fetchPeopleCallCount == 1)
    }

    @Test func loadRoutesToEmptyWhenNoRowsComeBack() async {
        let fake = FakePhotosCore()
        fake.tagsResult = .success([])
        let model = DiscoveryTilesModel(client: PhotosCoreClient(core: fake), kind: .tags)
        await model.load()
        #expect(model.route == .empty)
        #expect(model.tiles.isEmpty)
    }

    @Test func loadRoutesToFailedOnCoreError() async {
        let fake = FakePhotosCore()
        fake.placesResult = .failure(.Network(message: "offline"))
        let model = DiscoveryTilesModel(client: PhotosCoreClient(core: fake), kind: .places)
        await model.load()
        guard case .failed = model.route else {
            Issue.record("expected .failed, got \(model.route)")
            return
        }
        #expect(model.tiles.isEmpty)
    }

    @Test func loadFetchesSubjectsForSubjectsKind() async {
        let fake = FakePhotosCore()
        fake.subjectsResult = .success([Subject(id: 103, name: "Food", itemCount: 2)])
        let model = DiscoveryTilesModel(client: PhotosCoreClient(core: fake), kind: .subjects)
        await model.load()
        #expect(model.route == .tiles)
        #expect(fake.fetchSubjectsCallCount == 1)
        #expect(model.tiles.first?.collection == nil)
    }

    @Test func loadFetchesAlbumsForAlbumsKind() async {
        let fake = FakePhotosCore()
        fake.liveAlbumsResult = .success([
            Album(id: 5, name: "Trip", itemCount: 42, coverCacheKey: "COVER5", coverUnitId: 55805, isShared: false, isSmart: false, space: .personal),
        ])
        let model = DiscoveryTilesModel(client: PhotosCoreClient(core: fake), kind: .albums)
        await model.load()
        #expect(model.route == .tiles)
        #expect(fake.fetchLiveAlbumsCallCount == 1)
        #expect(model.tiles.first?.collection == .album(id: 5))
    }

    @Test func reloadStartsFromLoadingBeforeSettling() async {
        let fake = FakePhotosCore()
        fake.peopleResult = .success([Person(id: 1, name: "A", itemCount: 1, coverUnitId: nil, show: true)])
        let model = DiscoveryTilesModel(client: PhotosCoreClient(core: fake), kind: .people)
        #expect(model.route == .loading, "a freshly constructed model has not fetched yet")
        await model.load()
        #expect(model.route == .tiles)
    }
}
