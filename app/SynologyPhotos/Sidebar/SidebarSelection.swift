import PhotosCore

/// What the sidebar currently has highlighted, and therefore what the
/// content area on the right should show.
///
/// This is deliberately a separate, smaller enum from `SidebarItem`: the
/// sidebar can show a "Library" row that does not carry its own space (the
/// space comes from whichever `.space` row was picked most recently), so
/// the content-routing decision needs exactly two cases, not one per row.
enum SidebarSelectionRoute: Equatable {
    case grid(Space)
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
        case .albums: return .albums
        }
    }
}
