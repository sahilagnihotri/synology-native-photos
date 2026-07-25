import SwiftUI
import PhotosCore

/// Photos-style source list: a "Library" row (showing whichever space is
/// currently active), one row per space (Personal/Shared), a real "Albums"
/// row, and the Discovery section. Selecting a row drives `selection`,
/// which `LibraryView` reads through `SidebarItem.route(currentSpace:)` to
/// decide what the content area shows. Selecting "Albums" routes to the
/// same discovery-tiles/discovery-grid machinery People/Places/Tags use:
/// an album tile grid first, then that album's photos once a tile is
/// selected.
///
/// Uses `List(selection:)` with `.sidebar` styling rather than a bespoke
/// AppKit source list: this is exactly the case `NavigationSplitView` /
/// `List(selection:)` is built for, and it already gets the system-native
/// look (row highlight, section headers, spacing) for free.
struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(SidebarSections.libraryAndSpaces, id: \.self) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            Section("Albums") {
                ForEach(SidebarSections.albums, id: \.self) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
            Section("Discovery") {
                ForEach(SidebarSections.discovery, id: \.self) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
    }
}
