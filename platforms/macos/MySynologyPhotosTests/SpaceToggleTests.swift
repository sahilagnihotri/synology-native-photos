import Testing
import PhotosCore
@testable import MySynologyPhotos

@MainActor
struct SpaceToggleTests {
    private func asset(_ id: Int64, _ space: Space) -> Asset {
        Asset(id: id, unitId: id + 10_000, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000, addedAt: nil, width: 1, height: 1,
              fileSize: nil, space: space, serverVersion: id)
    }

    @Test func toggleSwitchesSpaceAndRequeries() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0), .personal) }
        fake.assets[.shared] = (0..<4).map { asset(Int64($0), .shared) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        fake.progressBySpace[.shared] = CrawlProgress(space: .shared, done: 4, total: 4, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        let sel = SpaceSelection(current: .personal)
        await sel.toggle(to: .shared, on: ds)
        #expect(sel.current == .shared)
        #expect(ds.totalCount == 4)
    }

    @Test func toggleToSameSpaceIsNoOp() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0), .personal) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        let ds = WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
        await ds.refreshCount()
        _ = ds.item(at: 0)
        let sel = SpaceSelection(current: .personal)
        await sel.toggle(to: .personal, on: ds)
        #expect(sel.current == .personal)
        #expect(ds.totalCount == 10)
    }
}
