import Testing
@testable import MySynologyPhotos

/// Exercises the pure clamp behind the zoom slider: `GridZoomModel` must
/// never let `itemSize` leave `[minItemSize, maxItemSize]`, regardless of
/// where the input value came from (slider drag, keyboard step, or a
/// future persisted default).
@MainActor
struct GridZoomModelTests {
    @Test func defaultsToDefaultItemSize() {
        let zoom = GridZoomModel()
        #expect(zoom.itemSize == GridZoomModel.defaultItemSize)
    }

    @Test func setClampsBelowMinimum() {
        let zoom = GridZoomModel()
        zoom.set(1)
        #expect(zoom.itemSize == GridZoomModel.minItemSize)
    }

    @Test func setClampsAboveMaximum() {
        let zoom = GridZoomModel()
        zoom.set(10_000)
        #expect(zoom.itemSize == GridZoomModel.maxItemSize)
    }

    @Test func setWithinRangeIsUnchanged() {
        let zoom = GridZoomModel()
        zoom.set(200)
        #expect(zoom.itemSize == 200)
    }

    @Test func stepGrowsAndShrinksWithinBounds() {
        let zoom = GridZoomModel(itemSize: 160)
        zoom.step(by: 20)
        #expect(zoom.itemSize == 180)
        zoom.step(by: -40)
        #expect(zoom.itemSize == 140)
    }

    @Test func stepClampsAtBoundaries() {
        let zoom = GridZoomModel(itemSize: GridZoomModel.maxItemSize)
        zoom.step(by: 50)
        #expect(zoom.itemSize == GridZoomModel.maxItemSize)

        let small = GridZoomModel(itemSize: GridZoomModel.minItemSize)
        small.step(by: -50)
        #expect(small.itemSize == GridZoomModel.minItemSize)
    }

    @Test func clampIsPureAndMatchesBounds() {
        #expect(GridZoomModel.clamp(GridZoomModel.minItemSize - 1) == GridZoomModel.minItemSize)
        #expect(GridZoomModel.clamp(GridZoomModel.maxItemSize + 1) == GridZoomModel.maxItemSize)
        #expect(GridZoomModel.clamp(200) == 200)
    }
}
