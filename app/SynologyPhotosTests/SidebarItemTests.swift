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

    @Test func albumsRowRoutesToAlbums() {
        #expect(SidebarItem.albums.route(currentSpace: .personal) == .albums)
    }
}
