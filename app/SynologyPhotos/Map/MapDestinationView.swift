import SwiftUI
import PhotosCore

/// The Map sidebar destination: loads the located photos for the current
/// space, shows a spinner while loading and a calm empty state when nothing
/// is located, and otherwise hosts the clustering map. Tapping a cluster or
/// a single pin opens a sheet of just those photos, and tapping one there
/// opens it in the app's real detail stack.
///
/// Renders full-bleed like `RecentlyDeletedView`: it is its own view, not the
/// photo grid.
struct MapDestinationView: View {
    let client: PhotosCoreClient
    let space: Space
    let thumbnailCache: ThumbnailCache
    let tempCache: TempFileCache
    let originalCache: OriginalImageCache
    let synoToken: String?

    @State private var model: MapModel
    /// The photos to show in the cluster sheet, or `nil` when it is closed.
    @State private var clusterSelection: MapClusterSelection?

    init(
        client: PhotosCoreClient,
        space: Space,
        thumbnailCache: ThumbnailCache,
        tempCache: TempFileCache,
        originalCache: OriginalImageCache,
        synoToken: String?
    ) {
        self.client = client
        self.space = space
        self.thumbnailCache = thumbnailCache
        self.tempCache = tempCache
        self.originalCache = originalCache
        self.synoToken = synoToken
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
            .sheet(item: $clusterSelection) { selection in
                MapClusterSheet(
                    assets: selection.assets,
                    space: space,
                    client: client,
                    cache: tempCache,
                    originalCache: originalCache,
                    thumbnailCache: thumbnailCache,
                    synoToken: synoToken)
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
                clusterSelection = MapClusterSelection(assets: assets)
            }
            .accessibilityIdentifier("map.mapview")
        }
    }
}

/// Identifiable wrapper so the cluster grid can be presented with
/// `.sheet(item:)`. Each tap is a distinct presentation, so a fresh id per
/// selection is exactly right.
struct MapClusterSelection: Identifiable {
    let id = UUID()
    let assets: [Asset]
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

/// The photos behind a tapped cluster or pin: a simple thumbnail grid (a
/// cluster is a bounded set, so `LazyVGrid` is fine here, unlike the 100k
/// library grid). Tapping a thumbnail opens it in the app's detail stack.
struct MapClusterSheet: View {
    let assets: [Asset]
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache
    let originalCache: OriginalImageCache
    let thumbnailCache: ThumbnailCache
    let synoToken: String?

    @Environment(\.dismiss) private var dismiss
    /// The index within `assets` currently open in the detail viewer, or `nil`
    /// when the grid is showing.
    @State private var detailIndex: Int?

    private let columns = [GridItem(.adaptive(minimum: 140), spacing: 12)]

    var body: some View {
        ZStack {
            grid
            if let index = detailIndex {
                MapPhotoDetailView(
                    assets: assets,
                    space: space,
                    client: client,
                    cache: cache,
                    originalCache: originalCache,
                    thumbnailCache: thumbnailCache,
                    synoToken: synoToken,
                    index: Binding(
                        get: { detailIndex ?? index },
                        set: { detailIndex = $0 }),
                    onClose: { detailIndex = nil })
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 680, minHeight: 520)
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack {
                Text(assets.count == 1 ? "1 Photo" : "\(assets.count) Photos")
                    .font(.headline)
                    .accessibilityIdentifier("map.cluster.title")
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("map.cluster.done")
            }
            .padding(12)
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(assets.enumerated()), id: \.element.id) { pair in
                        MapThumbnailCell(asset: pair.element, space: space, cache: thumbnailCache)
                            .onTapGesture { detailIndex = pair.offset }
                    }
                }
                .padding(12)
            }
            .accessibilityIdentifier("map.cluster.grid")
        }
    }
}

/// One thumbnail in the cluster grid. Loads through the app's existing
/// `ThumbnailCache` (memory + disk tiers), never a bespoke downloader, and
/// shows a small play badge over videos to match the library grid's own
/// cells.
struct MapThumbnailCell: View {
    let asset: Asset
    let space: Space
    let cache: ThumbnailCache

    @State private var image: CGImage?

    private static let side: CGFloat = 140

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.15))
            if let image {
                Image(image, scale: 1, label: Text(asset.filename))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Self.side, height: Self.side)
            } else {
                ProgressView().controlSize(.small)
            }
            if asset.mediaKind == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.5), in: Circle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(5)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .accessibilityIdentifier("map.cluster.cell")
        .task(id: asset.id) {
            image = await cache.image(space: space, asset: asset, size: .m)
        }
    }
}

/// A lightweight full-bleed viewer for a photo tapped in the cluster sheet.
///
/// Reuses the app's real detail render path verbatim: `DetailQuickLookView`
/// for stills (its two-tier `OriginalImageCache` load, downsampled decode,
/// pinch/double-click zoom, and thumbnail placeholder) and
/// `DetailVideoPlayerView` for true videos. It deliberately does NOT wrap the
/// full `DetailViewerHost`, only because that host also surfaces Delete and
/// Edit chrome that a v1 Map viewer has no wiring for; paging is provided
/// here with simple Previous/Next controls instead. No new download or decode
/// code is introduced.
struct MapPhotoDetailView: View {
    let assets: [Asset]
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache
    let originalCache: OriginalImageCache
    let thumbnailCache: ThumbnailCache
    let synoToken: String?
    @Binding var index: Int
    let onClose: () -> Void

    /// The current still's zoom, reset to fit on every paging move so a new
    /// photo always opens fitted, matching the library detail viewer.
    @State private var magnification: CGFloat = DetailZoomModel.fitScale

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if index >= 0, index < assets.count {
                let asset = assets[index]
                Group {
                    if asset.mediaKind == .video {
                        DetailVideoPlayerView(
                            asset: asset,
                            space: space,
                            client: client,
                            cache: cache,
                            originalCache: originalCache,
                            synoToken: synoToken)
                    } else {
                        DetailQuickLookView(
                            asset: asset,
                            space: space,
                            client: client,
                            originalCache: originalCache,
                            thumbnailCache: thumbnailCache,
                            magnification: $magnification)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                chrome
            }
        }
        .onChange(of: index) { _, _ in
            magnification = DetailZoomModel.fitScale
        }
        .accessibilityIdentifier("map.detail")
    }

    private var chrome: some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("map.detail.back")
            .accessibilityLabel("Back")

            Spacer()

            if assets.count > 1 {
                Text("\(index + 1) of \(assets.count)")
                    .font(.callout)
                    .foregroundStyle(.white)
                pagingButton(systemImage: "chevron.left.circle.fill", disabled: index <= 0) {
                    if index > 0 { index -= 1 }
                }
                .accessibilityIdentifier("map.detail.previous")
                pagingButton(systemImage: "chevron.right.circle.fill", disabled: index >= assets.count - 1) {
                    if index < assets.count - 1 { index += 1 }
                }
                .accessibilityIdentifier("map.detail.next")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func pagingButton(systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22))
                .foregroundStyle(.white)
                .opacity(disabled ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
