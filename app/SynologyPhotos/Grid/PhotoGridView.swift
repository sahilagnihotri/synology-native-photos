import SwiftUI
import AppKit

/// SwiftUI host for the AppKit grid controller.
///
/// `PhotoGridController` owns its `NSCollectionView`, diffable data source,
/// and prefetch wiring; this representable's only job is to hand that
/// already-configured controller to SwiftUI without re-creating or
/// re-configuring it on every view update. There is nothing in `controller`
/// for `updateNSViewController` to react to: space switches flow through
/// `WindowedDataSource`/`SpaceSelection`, and the controller re-applies its
/// own snapshot once that data source's counts change.
struct PhotoGridView: NSViewControllerRepresentable {
    let controller: PhotoGridController
    func makeNSViewController(context: Context) -> PhotoGridController { controller }
    func updateNSViewController(_ nsViewController: PhotoGridController, context: Context) {}
}
