import PhotosCore

/// One row in the Photos-style source list on the left.
///
/// `.library` always shows the currently selected space's grid (the space
/// itself is chosen by the `.space` rows below it, mirroring how Photos'
/// own sidebar has one "Library" row plus separate rows for other sources).
/// `.albums` is a placeholder section: albums are Phase 2 work, so this
/// case exists only so the sidebar can show an empty/coming-soon state
/// under a real "Albums" header rather than pretending albums exist.
enum SidebarItem: Hashable {
    case library
    case space(Space)
    case albums
}

/// Static sidebar layout: one Library row, one row per space, one Albums
/// placeholder. Kept as a plain array rather than something data-driven
/// since the set of rows is fixed for this phase (no user-created albums
/// yet); once Phase 2 adds real albums this becomes the seam that grows a
/// dynamic list under `.albums`.
enum SidebarSections {
    static let libraryAndSpaces: [SidebarItem] = [.library, .space(.personal), .space(.shared)]
    static let albums: [SidebarItem] = [.albums]
}

extension SidebarItem {
    /// Display title for the row.
    var title: String {
        switch self {
        case .library: return "Library"
        case .space(.personal): return "Personal"
        case .space(.shared): return "Shared"
        case .albums: return "Albums"
        }
    }

    /// SF Symbol for the row, matching Photos' own sidebar glyphs where a
    /// direct equivalent exists.
    var systemImage: String {
        switch self {
        case .library: return "photo.on.rectangle"
        case .space(.personal): return "person.crop.circle"
        case .space(.shared): return "person.2.circle"
        case .albums: return "rectangle.stack"
        }
    }
}
