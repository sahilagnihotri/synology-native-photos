import PhotosCore

/// What the sidebar currently has highlighted, and therefore what the
/// content area on the right should show.
///
/// This is deliberately a separate, smaller enum from `SidebarItem`: the
/// sidebar can show a "Library" row that does not carry its own space (the
/// space comes from whichever `.space` row was picked most recently), so
/// the content-routing decision needs one case for the library grid, plus
/// one more per discovery-browse destination. Albums reuses the exact same
/// two discovery-browse cases as People/Places/Tags: `.discoveryTiles(.albums)`
/// shows the album tile grid, and `.discoveryGrid(.album(id:))` shows one
/// album's photos, since an album is, from the content area's point of
/// view, just another discovery-browse collection with a tile step first.
///
/// `.discoveryTiles` shows the tile grid for a collection type (People,
/// Places, Subjects, Tags, Albums); `.discoveryGrid` shows the photo grid
/// for one selected tile, or directly for Favorites (which has no tile
/// step).
enum SidebarSelectionRoute: Equatable {
    case grid(Space)
    case discoveryTiles(DiscoveryKind)
    case discoveryGrid(DiscoveryCollection)
    /// The Recently Deleted view: the DSM recycle bin, shown as its own simple
    /// grid of `RecycleItem`s (not `Asset`s), with Restore and the gated
    /// Delete Permanently actions. The recycle bin is not space-scoped, so
    /// this case carries no `Space`.
    case recentlyDeleted
}

/// Which discovery-browse tile grid is being shown. A separate type from
/// `DiscoveryCollection` (the core's per-item filter) because a tile grid
/// is keyed on the collection *type* (People, the whole list), not a
/// single id.
enum DiscoveryKind: Equatable {
    case people
    case places
    case subjects
    case tags
    case albums
}

extension SidebarItem {
    /// Maps a clicked sidebar row plus the space currently active (from
    /// `SpaceSelection`) to what the content area should route to.
    /// `.library` and a `.space` row both resolve to the grid, just for
    /// different spaces; `.library` reuses whatever space was already
    /// selected rather than forcing a fixed default, so clicking "Library"
    /// after having chosen "Shared" keeps showing Shared.
    func route(currentSpace: Space) -> SidebarSelectionRoute {
        switch self {
        case .library: return .grid(currentSpace)
        case .space(let space): return .grid(space)
        case .albums: return .discoveryTiles(.albums)
        case .people: return .discoveryTiles(.people)
        case .places: return .discoveryTiles(.places)
        case .subjects: return .discoveryTiles(.subjects)
        case .tags: return .discoveryTiles(.tags)
        case .favorites: return .discoveryGrid(.favorites)
        case .recentlyDeleted: return .recentlyDeleted
        }
    }
}
