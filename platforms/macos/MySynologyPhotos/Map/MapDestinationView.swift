import SwiftUI
import PhotosCore

/// The Map sidebar destination: loads the located photos for the current
/// space, shows a spinner while loading and a calm empty state when nothing
/// is located, and otherwise hosts the clustering map. Tapping a cluster or a
/// single pin hands those photos UP to the host (`onOpenCluster`), which opens
/// them in the REAL library grid, so they inherit selection, delete, the full
/// detail viewer (stills and inline video), and context menus rather than a
/// second, weaker copy of the grid.
///
/// Renders full-bleed like `RecentlyDeletedView`: it is its own view, not the
/// photo grid.
struct MapDestinationView: View {
    let client: PhotosCoreClient
    let space: Space
    /// Called with the photos behind a tapped cluster or pin. The host routes
    /// them into the library grid (see `RootView.mapClusterAssets`).
    let onOpenCluster: ([Asset]) -> Void

    @State private var model: MapModel

    init(
        client: PhotosCoreClient,
        space: Space,
        onOpenCluster: @escaping ([Asset]) -> Void
    ) {
        self.client = client
        self.space = space
        self.onOpenCluster = onOpenCluster
        _model = State(initialValue: MapModel(client: client))
    }

    var body: some View {
        content
            // Loads on appear and reloads whenever the active space changes.
            .task(id: space) {
                if model.loadedSpace != space || !model.hasLoaded {
                    await model.load(space: space)
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView("Loading Map...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("map.progressview")
        } else if model.annotations.isEmpty {
            MapEmptyView()
        } else {
            PhotoMapView(annotations: model.annotations) { assets in
                onOpenCluster(assets)
            }
            .accessibilityIdentifier("map.mapview")
        }
    }
}

/// Shown when the located set is empty. Worded to reassure the user that an
/// empty map is a normal state (photos need GPS, and a fresh re-crawl may not
/// have repopulated coordinates yet), never an error.
struct MapEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mappin.slash")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Photos with Location")
                .font(.title2)
                .fontWeight(.medium)
            Text("Only photos that carry GPS location data appear on the map. Recently indexed photos may take a moment to show up here.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .accessibilityIdentifier("map.empty")
    }
}
