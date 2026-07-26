import SwiftUI
import AppKit
import MapKit
import PhotosCore

/// One located photo as an `MKAnnotation`. A class because `MKAnnotation` is
/// an Objective-C protocol; its coordinate is fixed at construction. Carries
/// the whole `Asset` so a tap can hand the real photo back to the app's
/// detail stack without a second lookup.
final class PhotoPointAnnotation: NSObject, MKAnnotation {
    let asset: Asset
    let coordinate: CLLocationCoordinate2D

    init(data: PhotoAnnotationData) {
        self.asset = data.asset
        self.coordinate = data.coordinate
        super.init()
    }

    var title: String? { asset.filename }
}

/// The map itself: an `MKMapView` wrapped in an `NSViewRepresentable`, using
/// MapKit's own annotation clustering (`clusteringIdentifier` /
/// `MKClusterAnnotation`) so dense areas collapse into a single count-badged
/// pin the user can tap. Deliberately the AppKit map rather than the SwiftUI
/// `Map`, because only the AppKit delegate gives clean cluster + tap
/// handling. Matches the app's established grid pattern of bridging a
/// configured AppKit view + a coordinator delegate into SwiftUI (see
/// `PhotoGridView` / `PhotoGridController`).
struct PhotoMapView: NSViewRepresentable {
    let annotations: [PhotoAnnotationData]
    /// Invoked with the assets behind a tapped pin (one asset) or a tapped
    /// cluster (its members), so the host can present those photos.
    let onSelect: ([Asset]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: Coordinator.pinReuseIdentifier)
        map.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        // Rebuild the pins only when the located set actually changes (a space
        // switch or the first load), so an ordinary SwiftUI re-render never
        // wipes and refits the map out from under the user's current pan/zoom.
        let incomingIds = annotations.map(\.asset.id)
        guard context.coordinator.appliedIds != incomingIds else { return }
        context.coordinator.appliedIds = incomingIds

        map.removeAnnotations(map.annotations)
        let points = annotations.map(PhotoPointAnnotation.init)
        guard !points.isEmpty else { return }
        map.addAnnotations(points)
        // Fit the initial region to every pin so the whole located set is
        // visible on first show, matching Photos' own map framing.
        map.showAnnotations(points, animated: false)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let pinReuseIdentifier = "PhotoPin"
        static let clusteringIdentifier = "PhotoCluster"

        var onSelect: ([Asset]) -> Void
        /// Asset ids of the annotations currently on the map, so `updateNSView`
        /// can skip a redundant rebuild.
        var appliedIds: [Int64] = []

        init(onSelect: @escaping ([Asset]) -> Void) {
            self.onSelect = onSelect
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            // A cluster MapKit created for us: a count-badged marker.
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: annotation) as? MKMarkerAnnotationView
                view?.annotation = cluster
                view?.markerTintColor = .systemBlue
                view?.glyphText = "\(cluster.memberAnnotations.count)"
                return view
            }
            // A single located photo: a photo-glyph marker that opts into
            // clustering so nearby pins collapse into a cluster as the user
            // zooms out.
            guard annotation is PhotoPointAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: Self.pinReuseIdentifier, for: annotation) as? MKMarkerAnnotationView
            view?.annotation = annotation
            view?.clusteringIdentifier = Self.clusteringIdentifier
            view?.markerTintColor = .systemBlue
            view?.glyphImage = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect annotationView: MKAnnotationView) {
            // Deselect immediately so tapping the same pin/cluster again
            // re-fires the selection (a selected annotation is otherwise
            // ignored on a repeat tap).
            if let annotation = annotationView.annotation {
                mapView.deselectAnnotation(annotation, animated: false)
            }
            if let cluster = annotationView.annotation as? MKClusterAnnotation {
                let assets = cluster.memberAnnotations.compactMap { ($0 as? PhotoPointAnnotation)?.asset }
                if !assets.isEmpty { onSelect(assets) }
            } else if let point = annotationView.annotation as? PhotoPointAnnotation {
                onSelect([point.asset])
            }
        }
    }
}
