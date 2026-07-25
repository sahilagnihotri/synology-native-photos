import SwiftUI
import PhotosCore

/// Tile grid for one discovery-browse kind (People/Places/Subjects/Tags).
///
/// A plain SwiftUI `LazyVGrid`, not the AppKit `NSCollectionView` the main
/// photo grid uses: that grid exists because a 20k-100k photo library
/// stutters in `LazyVGrid`, but a discovery collection list (a few dozen to
/// a few hundred people/places/tags) has no such problem, so the simpler
/// view is the right tool here.
///
/// Selecting a tile calls `onSelectCollection` with the tile's
/// `DiscoveryCollection`, or does nothing for a tile with no collection
/// (an unnamed person's disabled "Add Name" placeholder, or a Subject tile,
/// which has no working photo filter yet).
struct DiscoveryTileGridView: View {
    let model: DiscoveryTilesModel
    let cache: DiscoveryCoverCache
    let onSelectCollection: (DiscoveryCollection) -> Void

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 16)]

    var body: some View {
        Group {
            switch model.route {
            case .loading:
                ProgressView("Loading \(model.kind.title)...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("discovery.loading")
            case .empty:
                DiscoveryEmptyView(kind: model.kind)
            case .tiles:
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(model.tiles) { tile in
                            DiscoveryTileView(tile: tile, cache: cache) {
                                if let collection = tile.collection {
                                    onSelectCollection(collection)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
                .accessibilityIdentifier("discovery.tiles")
            case .failed(let message):
                DiscoveryFailedView(message: message) { await model.load() }
            }
        }
    }
}

/// One tile: a square cover (photo or glyph placeholder), a name (or the
/// disabled "Add Name" placeholder for an unnamed person), and an item
/// count. Read-only: tapping a nameless person or a subject with no
/// collection to route to is visibly disabled rather than silently doing
/// nothing, so the user is not left guessing why nothing happened.
private struct DiscoveryTileView: View {
    let tile: DiscoveryTile
    let cache: DiscoveryCoverCache
    let onSelect: () -> Void
    @State private var cover: Image?

    private var isSelectable: Bool { tile.collection != nil }

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                coverView
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) { badgeView }
                nameView
                Text("\(tile.itemCount) item\(tile.itemCount == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .opacity(isSelectable ? 1.0 : 0.6)
        .accessibilityIdentifier("discovery.tile.\(tile.id)")
        .task {
            guard let unitId = tile.coverUnitId else { return }
            cover = await cache.cover(unitId: unitId, cacheKey: tile.coverCacheKey)
        }
    }

    @ViewBuilder
    private var coverView: some View {
        if let cover {
            cover.resizable().scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.15))
                .overlay(Image(systemName: placeholderGlyph).font(.system(size: 32)).foregroundStyle(.secondary))
        }
    }

    private var placeholderGlyph: String {
        switch tile.collection {
        case .person: return "person.fill"
        case .place: return "map.fill"
        case .tag: return "tag.fill"
        case .album: return "rectangle.stack.fill"
        case .favorites, nil: return "square.grid.2x2"
        }
    }

    /// Small smart/shared indicator shown in the corner of an album's
    /// cover. Only ever non-empty for an Album tile (`isSmart`/`isShared`
    /// are hardcoded `false` on every other tile kind, see `DiscoveryTile`'s
    /// doc comment), so this is a no-op view for every other collection.
    @ViewBuilder
    private var badgeView: some View {
        if tile.isSmart || tile.isShared {
            HStack(spacing: 3) {
                if tile.isSmart {
                    Image(systemName: "gearshape.fill")
                        .accessibilityIdentifier("discovery.tile.\(tile.id).smartbadge")
                }
                if tile.isShared {
                    Image(systemName: "person.2.fill")
                        .accessibilityIdentifier("discovery.tile.\(tile.id).sharedbadge")
                }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(4)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(5)
        }
    }

    @ViewBuilder
    private var nameView: some View {
        if tile.isNameless {
            Label("Add Name", systemImage: "plus.circle")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .accessibilityIdentifier("discovery.tile.\(tile.id).addname")
        } else {
            Text(tile.displayName)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// Shown when a discovery collection has no rows at all (DSM has not
/// detected any people/places/subjects, or the user has created no tags).
/// Mirrors `EmptyLibraryView`'s visual language.
private struct DiscoveryEmptyView: View {
    let kind: DiscoveryKind

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No \(kind.title)")
                .font(.title2)
                .fontWeight(.medium)
            Text(kind.emptySubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("discovery.empty")
    }
}

/// Shown when the tile fetch itself failed. Mirrors `CrawlFailedView`'s
/// retry affordance.
private struct DiscoveryFailedView: View {
    let message: String
    let onRetry: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Could Not Load")
                .font(.title2)
                .fontWeight(.medium)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await onRetry() } }
                .accessibilityIdentifier("discovery.tryagain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("discovery.failed")
    }
}
