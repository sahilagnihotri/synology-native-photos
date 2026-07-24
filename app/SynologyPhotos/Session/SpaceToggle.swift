import SwiftUI
import PhotosCore

/// Personal/Shared selection. Switching re-queries the data source by space
/// (Personal => SYNO.Foto.*, Shared => SYNO.FotoTeam.* on the core side).
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

/// Segmented Personal/Shared control. Selecting a segment drives
/// `SpaceSelection.toggle(to:on:)`, which re-queries `dataSource` for the new
/// space, then calls `onChange` so the caller (typically the grid) can
/// refresh what it displays once the switch has settled.
struct SpaceToggleView: View {
    @State private var selection: SpaceSelection
    private let dataSource: WindowedDataSource
    private let onChange: () async -> Void

    init(selection: SpaceSelection, dataSource: WindowedDataSource, onChange: @escaping () async -> Void) {
        _selection = State(initialValue: selection)
        self.dataSource = dataSource
        self.onChange = onChange
    }

    var body: some View {
        Picker("Space", selection: Binding(
            get: { selection.current },
            set: { newValue in
                Task {
                    await selection.toggle(to: newValue, on: dataSource)
                    await onChange()
                }
            }
        )) {
            Text("Personal").tag(Space.personal)
            Text("Shared").tag(Space.shared)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("space.toggle")
    }
}
