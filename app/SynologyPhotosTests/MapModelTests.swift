import Testing
import Foundation
import PhotosCore
@testable import SynologyPhotos

/// Exercises the Map's model layer against `FakePhotosCore` (scripted via
/// `locatedAssetsResult` / `lastLocatedAssetsSpace`): it loads the located
/// assets for the active space, exposes them as plottable annotations, drops
/// rows with no coordinate, and stays graceful on an empty or failed load.
/// The AppKit `MKMapView` wrapper is not exercised here (user-verified).
@MainActor
struct MapModelTests {
    /// Builds an `Asset` with an optional coordinate via the full generated
    /// initializer, since the test fixture shim always defaults lat/lon to nil.
    private func asset(id: Int64, latitude: Double?, longitude: Double?) -> Asset {
        Asset(
            id: id,
            unitId: id,
            cacheKey: "key\(id)",
            filename: "IMG_\(id).jpg",
            mediaKind: .photo,
            takenAt: 1_600_000_000 + id,
            addedAt: nil,
            width: 4000,
            height: 3000,
            fileSize: 1_000,
            space: .personal,
            serverVersion: nil,
            rating: 0,
            description: "",
            camera: "",
            aperture: "",
            exposureTime: "",
            focalLength: "",
            iso: "",
            lens: "",
            duration: "",
            framerate: "",
            videoCodec: "",
            containerType: "",
            latitude: latitude,
            longitude: longitude)
    }

    @Test func loadsLocatedAssetsForTheCurrentSpace() async {
        let fake = FakePhotosCore()
        fake.locatedAssetsResult = .success([
            asset(id: 1, latitude: 59.91, longitude: 10.75),
            asset(id: 2, latitude: 51.50, longitude: -0.12),
        ])
        let model = MapModel(client: PhotosCoreClient(core: fake))

        await model.load(space: .personal)

        #expect(model.hasLoaded)
        #expect(model.annotations.count == 2)
        #expect(model.errorMessage == nil)
        #expect(fake.locatedAssetsCallCount == 1)
        #expect(fake.lastLocatedAssetsSpace == .personal)
    }

    @Test func exposesEachLocatedAssetAsAnAnnotationCarryingItsCoordinate() async {
        let fake = FakePhotosCore()
        fake.locatedAssetsResult = .success([
            asset(id: 7, latitude: 59.91, longitude: 10.75),
        ])
        let model = MapModel(client: PhotosCoreClient(core: fake))

        await model.load(space: .personal)

        let annotation = model.annotations.first
        #expect(annotation?.asset.id == 7)
        #expect(annotation?.latitude == 59.91)
        #expect(annotation?.longitude == 10.75)
        #expect(annotation?.coordinate.latitude == 59.91)
        #expect(annotation?.coordinate.longitude == 10.75)
        #expect(annotation?.id == 7)
    }

    @Test func dropsRowsThatHaveNoCoordinate() async {
        // A row missing latitude or longitude cannot be plotted, so it must be
        // filtered out even if the core hands one back.
        let fake = FakePhotosCore()
        fake.locatedAssetsResult = .success([
            asset(id: 1, latitude: 59.91, longitude: 10.75),
            asset(id: 2, latitude: nil, longitude: 10.75),
            asset(id: 3, latitude: 51.50, longitude: nil),
        ])
        let model = MapModel(client: PhotosCoreClient(core: fake))

        await model.load(space: .personal)

        #expect(model.annotations.count == 1)
        #expect(model.annotations.first?.asset.id == 1)
    }

    @Test func handlesAnEmptyLocatedSetGracefully() async {
        // The graceful empty state that matters right after an upgrade that
        // re-crawls: loaded, empty, and NOT an error.
        let fake = FakePhotosCore()
        fake.locatedAssetsResult = .success([])
        let model = MapModel(client: PhotosCoreClient(core: fake))

        await model.load(space: .personal)

        #expect(model.hasLoaded)
        #expect(model.annotations.isEmpty)
        #expect(model.errorMessage == nil)
    }

    @Test func loadsForTheRequestedSpace() async {
        let fake = FakePhotosCore()
        fake.locatedAssetsResult = .success([])
        let model = MapModel(client: PhotosCoreClient(core: fake))

        await model.load(space: .shared)

        #expect(fake.lastLocatedAssetsSpace == .shared)
        #expect(model.loadedSpace == .shared)
    }

    @Test func recordsAMessageAndStaysEmptyOnFailure() async {
        let fake = FakePhotosCore()
        fake.locatedAssetsResult = .failure(.Network(message: "offline"))
        let model = MapModel(client: PhotosCoreClient(core: fake))

        await model.load(space: .personal)

        #expect(model.hasLoaded)
        #expect(model.annotations.isEmpty)
        #expect(model.errorMessage != nil)
    }
}
