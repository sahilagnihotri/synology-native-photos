import Testing
import PhotosCore
@testable import SynologyPhotos

/// Exercises the pure routing decision behind the sidebar: which content
/// area route a clicked row resolves to, given whatever space is currently
/// active. Kept separate from any SwiftUI view so the decision is testable
/// without a live `NavigationSplitView`.
struct SidebarItemTests {
    @Test func libraryRowRoutesToCurrentSpace() {
        #expect(SidebarItem.library.route(currentSpace: .personal) == .grid(.personal))
        #expect(SidebarItem.library.route(currentSpace: .shared) == .grid(.shared))
    }

    @Test func spaceRowRoutesToItsOwnSpaceRegardlessOfCurrent() {
        #expect(SidebarItem.space(.shared).route(currentSpace: .personal) == .grid(.shared))
        #expect(SidebarItem.space(.personal).route(currentSpace: .shared) == .grid(.personal))
    }

    @Test func albumsRowRoutesToAlbumsDiscoveryTiles() {
        #expect(SidebarItem.albums.route(currentSpace: .personal) == .discoveryTiles(.albums))
        #expect(SidebarItem.albums.route(currentSpace: .shared) == .discoveryTiles(.albums),
                "albums routing must not depend on the currently active space")
    }

    @Test func discoveryTileRowsRouteToTheirOwnKind() {
        #expect(SidebarItem.people.route(currentSpace: .personal) == .discoveryTiles(.people))
        #expect(SidebarItem.places.route(currentSpace: .personal) == .discoveryTiles(.places))
        #expect(SidebarItem.subjects.route(currentSpace: .personal) == .discoveryTiles(.subjects))
        #expect(SidebarItem.tags.route(currentSpace: .personal) == .discoveryTiles(.tags))
    }

    @Test func favoritesRowSkipsTilesAndGoesStraightToTheGrid() {
        #expect(SidebarItem.favorites.route(currentSpace: .personal) == .discoveryGrid(.favorites))
        #expect(SidebarItem.favorites.route(currentSpace: .shared) == .discoveryGrid(.favorites),
                "favorites routing must not depend on the currently active space")
    }

    @Test func discoveryRowTitlesAndGlyphsAreDistinctPerKind() {
        let discoveryRows: [SidebarItem] = [.people, .places, .subjects, .tags, .favorites]
        #expect(Set(discoveryRows.map(\.title)).count == discoveryRows.count, "every discovery row needs a distinct title")
        #expect(Set(discoveryRows.map(\.systemImage)).count == discoveryRows.count, "every discovery row needs a distinct glyph")
    }
}
