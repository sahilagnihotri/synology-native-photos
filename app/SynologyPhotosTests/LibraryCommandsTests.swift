import Testing
@testable import SynologyPhotos

/// Exercises the pure enable/disable decision behind the app's menu bar, kept
/// out of any SwiftUI scene so "which menu commands apply in this UI state" is
/// testable without a live window.
struct LibraryCommandsTests {
    @Test func zoomOnlyAppliesToThePhotoGridWithTheViewerClosed() {
        let onGrid = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: true, isViewerOpen: false, canUndoDelete: false)
        #expect(onGrid.canZoom)

        // Viewer open over the grid: zoom is the viewer's own slider/pinch, so
        // the grid-zoom menu items must grey out.
        let viewerOpen = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: true, isViewerOpen: true, canUndoDelete: false)
        #expect(!viewerOpen.canZoom)

        // A tile grid / recycle bin (not a photo grid) has nothing to zoom.
        let onTiles = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: false, isViewerOpen: false, canUndoDelete: false)
        #expect(!onTiles.canZoom)
    }

    @Test func toggleInfoOnlyAppliesWhileTheViewerIsOpen() {
        let viewerOpen = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: true, isViewerOpen: true, canUndoDelete: false)
        #expect(viewerOpen.canToggleInfo)

        let viewerClosed = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: true, isViewerOpen: false, canUndoDelete: false)
        #expect(!viewerClosed.canToggleInfo)
    }

    @Test func undoDeleteTracksTheDeleteControllerFlag() {
        let canUndo = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: false, isViewerOpen: false, canUndoDelete: true)
        #expect(canUndo.canUndoDelete)

        let cannotUndo = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: true, isViewerOpen: false, canUndoDelete: false)
        #expect(!cannotUndo.canUndoDelete)
    }

    @Test func sidebarToggleIsAlwaysAvailable() {
        let anyState = LibraryCommandAvailability.compute(
            isShowingPhotoGrid: false, isViewerOpen: false, canUndoDelete: false)
        #expect(anyState.canToggleSidebar)
    }
}
