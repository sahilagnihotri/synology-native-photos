import PhotosCore

/// One row in the Photos-style source list on the left.
///
/// `.library` always shows the currently selected space's grid (the space
/// itself is chosen by the `.space` rows below it, mirroring how Photos'
/// own sidebar has one "Library" row plus separate rows for other sources).
/// `.albums` shows the real Albums tile grid (cover + name/count, smart/
/// shared badges), fetched live from the NAS the same way People/Places/
/// Tags are; selecting an album tile drills into the existing photo grid.
/// Read-only for this pass: no create/rename/add-to/remove-from album yet.
///
/// `.people`/`.places`/`.subjects`/`.tags` are discovery-browse sections:
/// selecting one shows a tile grid of that collection type (cover +
/// name/count), and selecting a tile drills into the existing photo grid.
/// `.favorites` skips the tile step entirely and goes straight to a photo
/// grid, since there is only ever one favorites collection.
enum SidebarItem: Hashable {
    case library
    case space(Space)
    case albums
    case people
    case places
    case subjects
    case tags
    case favorites
    /// The Map view: located photos plotted on a map, clustered by proximity,
    /// where tapping a cluster (or a single pin) opens the photos taken there.
    case map
    /// The app-owned Recently Deleted view: a grid of soft-deleted items that
    /// can be restored, or permanently deleted from there (and only there).
    /// Mirrors Photos' own "Recently Deleted" source-list row.
    case recentlyDeleted
}

/// Static sidebar layout: one Library row, one row per space, one Albums
/// row, and the discovery-browse sections. Kept as a plain array rather
/// than something data-driven since the set of top-level rows is fixed;
/// the actual album list underneath `.albums` is fetched live and rendered
/// as a tile grid, the same way People/Places/Tags already work.
enum SidebarSections {
    static let libraryAndSpaces: [SidebarItem] = [.library, .space(.personal), .space(.shared)]
    /// The Map row, shown on its own between the spaces and Albums.
    static let map: [SidebarItem] = [.map]
    static let albums: [SidebarItem] = [.albums]
    /// `.subjects` is deliberately omitted here: on this NAS a subject tile
    /// routes to nothing (no working photo filter for Concept/Subjects, see
    /// `DiscoveryTile.init(subject:)`), so listing a section whose tiles do
    /// nothing is worse than not shipping it. The `.subjects` case, its
    /// title/glyph, and its routing are all left intact, so re-listing it is
    /// a one-line change once a future DSM exposes the filter.
    static let discovery: [SidebarItem] = [.people, .places, .tags, .favorites]
    /// Utility rows shown at the bottom of the sidebar, matching Photos' own
    /// placement of Recently Deleted below the main sources.
    static let utilities: [SidebarItem] = [.recentlyDeleted]
}

extension SidebarItem {
    /// Display title for the row.
    var title: String {
        switch self {
        case .library: return "Library"
        case .space(.personal): return "Personal"
        case .space(.shared): return "Shared"
        case .albums: return "Albums"
        case .people: return "People"
        case .places: return "Places"
        case .subjects: return "Subjects"
        case .tags: return "Tags"
        case .favorites: return "Favorites"
        case .map: return "Map"
        case .recentlyDeleted: return "Recently Deleted"
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
        case .people: return "person.2.crop.square.stack"
        case .places: return "map"
        case .subjects: return "square.grid.2x2"
        case .tags: return "tag"
        case .favorites: return "heart"
        // A globe rather than `.places`' own "map" glyph, so the two rows stay
        // visually distinct in the sidebar.
        case .map: return "globe.americas"
        case .recentlyDeleted: return "trash"
        }
    }
}
