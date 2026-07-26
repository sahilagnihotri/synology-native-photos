import Foundation
import CoreLocation
import PhotosCore

/// One located photo plotted on the map: the asset plus its resolved
/// coordinate. Kept as a plain value type (not the AppKit `MKAnnotation`
/// class) so the model layer, and its tests, never have to touch MapKit;
/// `PhotoMapView` wraps each of these in an `MKAnnotation` when it builds
/// the map.
struct PhotoAnnotationData: Identifiable {
    let asset: Asset
    let latitude: Double
    let longitude: Double

    var id: Int64 { asset.id }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Backs the Map view: loads every located photo in a space through
/// `locatedAssets(space:)` and exposes them as annotation data for the map.
///
/// A local-index read (no crawl barrier, no windowing): the located set is
/// bounded by however many of the user's photos carry GPS, which is far
/// smaller than the whole library, so the whole set is fetched at once the
/// way the discovery tile lists are.
///
/// GRACEFUL EMPTY STATE: the GPS columns are populated by the crawl, and
/// were added in a `requires_recrawl` schema step, so on the first launch
/// after that upgrade `locatedAssets` can briefly return nothing while the
/// re-crawl repopulates lat/lon. `hasLoaded` lets the view tell "still
/// loading" from "loaded and genuinely empty" so that transient window
/// shows the calm empty state, never an error.
@MainActor
@Observable
final class MapModel {
    private let client: PhotosCoreClient

    /// The located photos, newest first (the order the core returns), each
    /// carrying a non-nil coordinate. Rows the core returns without a usable
    /// coordinate are filtered out here so every annotation is plottable.
    private(set) var annotations: [PhotoAnnotationData] = []
    /// True once at least one load has completed, so the view can distinguish
    /// "not loaded yet" (spinner) from "loaded and empty" (empty state).
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    /// The space the currently held annotations were loaded for, so a repeated
    /// load for the same space can be skipped and a space change forces a reload.
    private(set) var loadedSpace: Space?
    /// Surfaced to the view when a load throws. Nil while there is nothing to
    /// report.
    var errorMessage: String?

    init(client: PhotosCoreClient) {
        self.client = client
    }

    /// Loads (or reloads) the located photos for `space`. Filters out any row
    /// missing a latitude or longitude so every published annotation is
    /// plottable. On failure it clears the annotations and records a
    /// user-facing message rather than throwing, since the Map view treats a
    /// failed load like any other empty result.
    func load(space: Space) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let assets = try await client.locatedAssets(space: space)
            annotations = assets.compactMap { asset in
                guard let latitude = asset.latitude, let longitude = asset.longitude else { return nil }
                return PhotoAnnotationData(asset: asset, latitude: latitude, longitude: longitude)
            }
            errorMessage = nil
        } catch {
            annotations = []
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not load the map."
        }
        loadedSpace = space
        hasLoaded = true
    }
}
