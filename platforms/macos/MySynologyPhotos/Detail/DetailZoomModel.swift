import Foundation

/// Pure clamping/reset logic behind the detail viewer's zoom, kept free of
/// `NSScrollView`/`NSMagnificationGestureRecognizer` so the bounds are
/// directly testable without a live window.
///
/// The detail viewer zooms the already-loaded image in place (no bytes are
/// re-fetched at a higher resolution): scroll/pinch magnify the content an
/// `NSScrollView` already hosts, and this type only decides what
/// magnification value is actually allowed to land.
enum DetailZoomModel {
    /// The un-zoomed, fit-to-view scale. `NSScrollView.magnification` uses
    /// `1.0` as "no zoom applied", matching how the view is first presented.
    static let fitScale: CGFloat = 1.0

    /// Matches the spec's "clamp fit..~8x": far enough to inspect detail on
    /// a high-resolution photo, not so far a raster image dissolves into
    /// meaningless blocks.
    static let maxScale: CGFloat = 8.0

    /// Clamps a proposed magnification (from a scroll-wheel or pinch event)
    /// to `[fitScale, maxScale]`. Below `fitScale` the photo would shrink
    /// smaller than its fitted frame, which is not "zoom" at all in this
    /// viewer (there is no separate zoomed-out state); above `maxScale` the
    /// image is already far past any useful detail.
    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, fitScale), maxScale)
    }

    /// Whether `scale` counts as "zoomed in" for purposes of deciding
    /// pan-vs-page behavior and whether to show a reset-to-fit affordance.
    /// A small epsilon absorbs floating-point noise from repeated
    /// incremental magnification deltas landing a hair off `1.0`.
    private static let zoomedEpsilon: CGFloat = 0.001
    static func isZoomed(_ scale: CGFloat) -> Bool {
        scale > fitScale + zoomedEpsilon
    }
}
