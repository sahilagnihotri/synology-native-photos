import SwiftUI

/// Toolbar zoom control: fewer/larger thumbnails on the right, more/smaller
/// on the left, matching the orientation of Photos' own zoom slider.
/// Dragging calls `onChange` live so the grid resizes as the slider moves,
/// not only once dragging ends.
struct ZoomSliderView: View {
    @State var zoom: GridZoomModel
    let onChange: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(
                value: Binding(
                    get: { zoom.itemSize },
                    set: { newValue in
                        zoom.set(newValue)
                        onChange(zoom.itemSize)
                    }
                ),
                in: GridZoomModel.minItemSize...GridZoomModel.maxItemSize
            )
            .frame(width: 120)
            .accessibilityIdentifier("grid.zoom.slider")
            Image(systemName: "photo.fill")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}
