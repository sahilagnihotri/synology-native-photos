import SwiftUI
import PhotosCore

/// Photos-style source list: a "Library" row (showing whichever space is
/// currently active), one row per space (Personal/Shared), and an "Albums"
/// section placeholder. Selecting a row drives `selection`, which
/// `LibraryView` reads through `SidebarItem.route(currentSpace:)` to decide
/// what the content area shows.
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
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("sidebar.list")
    }
}

/// Shown when the "Albums" sidebar row is selected. Albums themselves are
/// Phase 2 work (creating, naming, adding photos to them); this is an
/// honest "not built yet" placeholder rather than any fake album content,
/// matching the brief's instruction not to fake the feature.
struct AlbumsComingSoonView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Albums")
                .font(.title2)
                .fontWeight(.medium)
            Text("Albums are coming in a future update.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("albums.comingsoon")
    }
}
