import SwiftUI

/// The subset of the running library/viewer's actions the app's menu bar can
/// invoke, published by `LibraryView` through `.focusedSceneValue` so the
/// `.commands` block can reach the live controllers without owning them.
///
/// Each closure is optional: `nil` means the action does not apply right now
/// (nothing on screen to zoom, no photo open to show info for, nothing to
/// undo), which the menu turns into a greyed-out item. The menu is purely an
/// additive, discoverable surface over actions that already work from the
/// keyboard; both paths stay live.
///
/// Select All and Delete are deliberately absent here: they are wired through
/// the grid's own responder chain (`KeyHandlingCollectionView.selectAll(_:)` /
/// `delete(_:)`) so the standard Edit-menu items drive them, which keeps them
/// focus-aware (a focused text field still gets its own Select All / delete)
/// and avoids a duplicate or a conflicting Cmd-A key equivalent.
struct LibraryCommandActions {
    var undoDelete: (() -> Void)?
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var toggleInfo: (() -> Void)?
    var toggleSidebar: (() -> Void)?
}

/// Pure availability decision behind the menu items, split out of the SwiftUI
/// view so "which commands are enabled given the current UI state" is
/// unit-testable without a live scene. `LibraryView` uses this to decide which
/// closures on `LibraryCommandActions` to populate (a `nil` closure greys the
/// item out).
struct LibraryCommandAvailability: Equatable {
    var canUndoDelete: Bool
    var canZoom: Bool
    var canToggleInfo: Bool
    /// The sidebar toggle is always available (a window always has a sidebar
    /// to show or hide), so it is a constant rather than a computed field.
    let canToggleSidebar = true

    /// - Parameters:
    ///   - isShowingPhotoGrid: a real photo grid (library/collection/search),
    ///     not a tile grid or the recycle bin, is on screen.
    ///   - isViewerOpen: the full-photo detail viewer is open over the grid.
    ///   - canUndoDelete: the delete controller has a just-deleted set to
    ///     restore.
    ///
    /// Zoom applies to the grid only (the viewer has its own slider/pinch), so
    /// it is offered only while a photo grid is showing and the viewer is not
    /// covering it. Show/Hide Info toggles the viewer's info panel, so it is
    /// offered only while the viewer is open.
    static func compute(isShowingPhotoGrid: Bool, isViewerOpen: Bool, canUndoDelete: Bool) -> LibraryCommandAvailability {
        LibraryCommandAvailability(
            canUndoDelete: canUndoDelete,
            canZoom: isShowingPhotoGrid && !isViewerOpen,
            canToggleInfo: isViewerOpen)
    }
}

private struct LibraryCommandActionsKey: FocusedValueKey {
    typealias Value = LibraryCommandActions
}

extension FocusedValues {
    /// The running library/viewer's menu-command closures, or `nil` when no
    /// library window is key (e.g. only the About or Settings window is up).
    var libraryCommands: LibraryCommandActions? {
        get { self[LibraryCommandActionsKey.self] }
        set { self[LibraryCommandActionsKey.self] = newValue }
    }
}

/// The app's real menu bar: File/Edit/View items that surface actions the app
/// already implements, so they are discoverable rather than only typeable.
/// Reads the running library/viewer's closures out of the focused scene and
/// greys each item out when its closure is absent.
///
/// Select All and Delete are not built here: SwiftUI's standard Edit menu
/// already carries them, and the grid makes them work by responding to
/// `selectAll(_:)` / `delete(_:)` on the responder chain.
struct LibraryCommands: Commands {
    @FocusedValue(\.libraryCommands) private var actions

    var body: some Commands {
        // Edit: the app's only undo is bringing back the last delete, so the
        // stock Undo/Redo pair is replaced with a single, honestly-named item.
        // Disabled when there is nothing to bring back, so Cmd-Z falls through
        // to a focused text field's own undo in that case.
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Delete") { actions?.undoDelete?() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(actions?.undoDelete == nil)
        }

        // View: the sidebar toggle drives our own column-visibility state
        // (replacing the stock one so the menu item and any toolbar toggle
        // agree), plus the grid zoom and the viewer's info panel.
        CommandGroup(replacing: .sidebar) {
            Button("Show/Hide Sidebar") { actions?.toggleSidebar?() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(actions?.toggleSidebar == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom In") { actions?.zoomIn?() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions?.zoomIn == nil)
            Button("Zoom Out") { actions?.zoomOut?() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions?.zoomOut == nil)
            Divider()
            Button("Show/Hide Info") { actions?.toggleInfo?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(actions?.toggleInfo == nil)
        }
    }
}
