import Foundation
import PhotosCore

/// The four states a discovery-browse tile grid can be in. Mirrors the
/// shape of `LibraryContentRoute` in `RootView.swift`: loading, empty, a
/// real result, or a failure with a retry affordance, so the same visual
/// vocabulary (spinner / empty placeholder / grid / failed-with-retry)
/// extends to People/Places/Subjects/Tags instead of inventing a new one.
enum DiscoveryTilesRoute: Equatable {
    case loading
    case empty
    case tiles
    case failed(message: String)
}

/// Fetches and holds the tile list for one discovery-browse kind
/// (People/Places/Subjects/Tags). Unlike `WindowedDataSource`, these
/// collections have no local index in this pass and are typically small
/// (a handful to a few hundred rows), so this fetches the whole list in one
/// call rather than windowing it.
@MainActor
@Observable
final class DiscoveryTilesModel {
    private let client: PhotosCoreClient
    let kind: DiscoveryKind
    private(set) var tiles: [DiscoveryTile] = []
    private(set) var route: DiscoveryTilesRoute = .loading

    /// Ceiling on how many rows a single fetch asks for. Discovery
    /// collections are not expected to run into the tens of thousands the
    /// way a photo library can, so one bounded page covers the realistic
    /// case; a library with more than this many people/places/tags would
    /// need real windowing, which is out of scope for this pass.
    private static let fetchLimit: UInt32 = 500

    init(client: PhotosCoreClient, kind: DiscoveryKind) {
        self.client = client
        self.kind = kind
    }

    /// Fetches (or re-fetches) the tile list from the core. Always a live
    /// network call; there is no local cache to fall back to first.
    func load() async {
        route = .loading
        do {
            let fetched: [DiscoveryTile]
            switch kind {
            case .people:
                fetched = try await client.fetchPeople(offset: 0, limit: Self.fetchLimit).map(DiscoveryTile.init(person:))
            case .places:
                fetched = try await client.fetchPlaces(offset: 0, limit: Self.fetchLimit).map(DiscoveryTile.init(place:))
            case .subjects:
                fetched = try await client.fetchSubjects(offset: 0, limit: Self.fetchLimit).map(DiscoveryTile.init(subject:))
            case .tags:
                fetched = try await client.fetchTags(offset: 0, limit: Self.fetchLimit).map(DiscoveryTile.init(tag:))
            }
            tiles = fetched
            route = fetched.isEmpty ? .empty : .tiles
        } catch {
            tiles = []
            route = .failed(message: Self.message(for: error))
        }
    }

    private static func message(for error: Error) -> String {
        if let coreError = error as? CoreError { return coreError.userMessage }
        return "Could not load this list."
    }
}

extension DiscoveryKind {
    /// Display title for the tile-grid content area header.
    var title: String {
        switch self {
        case .people: return "People"
        case .places: return "Places"
        case .subjects: return "Subjects"
        case .tags: return "Tags"
        }
    }

    /// SF Symbol for the empty-state placeholder, matching the sidebar's
    /// own glyph for this kind.
    var systemImage: String {
        switch self {
        case .people: return "person.2.crop.square.stack"
        case .places: return "map"
        case .subjects: return "square.grid.2x2"
        case .tags: return "tag"
        }
    }

    /// Empty-state subtitle, worded per kind so "nothing here yet" reads
    /// naturally regardless of which discovery section it is shown under.
    var emptySubtitle: String {
        switch self {
        case .people: return "DSM has not detected any people in your photos yet."
        case .places: return "DSM has not detected any locations in your photos yet."
        case .subjects: return "DSM has not detected any subjects in your photos yet."
        case .tags: return "You have not created any tags yet."
        }
    }
}
