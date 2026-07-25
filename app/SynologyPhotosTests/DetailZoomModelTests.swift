import Testing
@testable import SynologyPhotos

/// Exercises the pure clamp/state logic behind the detail viewer's
/// scroll/pinch zoom, independent of any live `NSScrollView`.
struct DetailZoomModelTests {
    @Test func clampLeavesAnInRangeValueUnchanged() {
        #expect(DetailZoomModel.clamp(2.5) == 2.5)
    }

    @Test func clampFloorsAtFitScale() {
        #expect(DetailZoomModel.clamp(0.2) == DetailZoomModel.fitScale)
        #expect(DetailZoomModel.clamp(0) == DetailZoomModel.fitScale)
        #expect(DetailZoomModel.clamp(-3) == DetailZoomModel.fitScale)
    }

    @Test func clampCeilingsAtMaxScale() {
        #expect(DetailZoomModel.clamp(50) == DetailZoomModel.maxScale)
        #expect(DetailZoomModel.clamp(DetailZoomModel.maxScale + 0.01) == DetailZoomModel.maxScale)
    }

    @Test func clampAtExactBoundsIsIdempotent() {
        #expect(DetailZoomModel.clamp(DetailZoomModel.fitScale) == DetailZoomModel.fitScale)
        #expect(DetailZoomModel.clamp(DetailZoomModel.maxScale) == DetailZoomModel.maxScale)
    }

    @Test func fitScaleIsNotConsideredZoomed() {
        #expect(DetailZoomModel.isZoomed(DetailZoomModel.fitScale) == false)
    }

    @Test func aboveFitScaleIsConsideredZoomed() {
        #expect(DetailZoomModel.isZoomed(1.5) == true)
        #expect(DetailZoomModel.isZoomed(DetailZoomModel.maxScale) == true)
    }

    @Test func tinyFloatingPointNoiseAroundFitScaleIsNotConsideredZoomed() {
        // Repeated incremental magnification deltas can land a hair off
        // 1.0; that must not register as "zoomed in" and start showing a
        // reset-to-fit affordance for what is visually still the fit state.
        #expect(DetailZoomModel.isZoomed(DetailZoomModel.fitScale + 0.0001) == false)
    }

    @Test func belowFitScaleIsNotConsideredZoomed() {
        // There is no separate zoomed-out state in this viewer; anything at
        // or below fit reads as "not zoomed".
        #expect(DetailZoomModel.isZoomed(0.5) == false)
    }
}
