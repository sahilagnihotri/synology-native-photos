import Observation
import PhotosCore

/// Personal/Shared selection. Switching re-queries the data source by space
/// (Personal => SYNO.Foto.*, Shared => SYNO.FotoTeam.* on the core side).
///
/// The segmented control that used to drive this directly has been replaced
/// by the sidebar (`SidebarView`); this type is unchanged and is now driven
/// from `LibraryView.switchSpace(to:)` instead.
@MainActor
@Observable
final class SpaceSelection {
    var current: Space
    init(current: Space) { self.current = current }

    /// Flips `current` to `space` and asks `dataSource` to re-query for it.
    /// A same-space toggle is a no-op: `WindowedDataSource.setSpace` clears
    /// the resident cache and re-fetches count/readiness, which would be
    /// wasted work (and a visible flash) if the space did not actually
    /// change.
    func toggle(to space: Space, on dataSource: WindowedDataSource) async {
        guard space != current else { return }
        current = space
        await dataSource.setSpace(space)
    }
}
