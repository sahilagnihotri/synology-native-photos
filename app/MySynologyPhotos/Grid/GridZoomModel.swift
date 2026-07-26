import Foundation
import Observation

/// The zoom slider's backing model: a single clamped item-size value the
/// toolbar control and the grid controller both read.
///
/// Kept as a plain `@Observable` wrapper around one clamped `Double` rather
/// than exposing the raw slider value directly, so every write goes through
/// `GridZoomModel.clamp(_:)`: a value coming from persisted state, a
/// keyboard shortcut, or a future "fit to window" action can never push the
/// grid's item size outside the range Photos itself uses (very small
/// thumbnails at one end, one-or-two-per-row large previews at the other).
@MainActor
@Observable
final class GridZoomModel {
    /// Smallest square item size, in points. Below this, Photos-style tiny
    /// thumbnails stop being individually tappable.
    static let minItemSize: CGFloat = 60
    /// Largest square item size, in points. Above this a single row holds
    /// only one or two items, which is still useful (matches Photos' own
    /// max zoom) but no larger.
    static let maxItemSize: CGFloat = 320
    static let defaultItemSize: CGFloat = 160

    private(set) var itemSize: CGFloat

    init(itemSize: CGFloat = GridZoomModel.defaultItemSize) {
        self.itemSize = GridZoomModel.clamp(itemSize)
    }

    /// Sets `itemSize` to `value`, clamped to `[minItemSize, maxItemSize]`.
    func set(_ value: CGFloat) {
        itemSize = Self.clamp(value)
    }

    /// Nudges `itemSize` by `delta` (positive grows, negative shrinks),
    /// still clamped. Used by toolbar +/- buttons.
    func step(by delta: CGFloat) {
        set(itemSize + delta)
    }

    /// Pure clamp, extracted for testing without touching the
    /// `@Observable` instance.
    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minItemSize), maxItemSize)
    }
}
