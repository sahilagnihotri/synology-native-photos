import Testing
@testable import SynologyPhotos

/// Exercises the pure click/shift/cmd/select-all transitions behind the
/// grid's multi-select, independent of any `NSCollectionView`. This is the
/// model future delete/album actions read, so its behavior on each gesture
/// must match Finder/Photos exactly.
@MainActor
struct PhotoSelectionModelTests {
    @Test func startsEmpty() {
        let model = PhotoSelectionModel()
        #expect(model.isEmpty)
        #expect(model.count == 0)
        #expect(model.anchor == nil)
    }

    @Test func plainClickReplacesSelectionAndMovesAnchor() {
        let model = PhotoSelectionModel()
        model.click(5)
        #expect(model.selected == [5])
        #expect(model.anchor == 5)

        model.click(9)
        #expect(model.selected == [9])
        #expect(model.anchor == 9)
    }

    @Test func cmdToggleAddsWithoutClearingRestAndDoesNotMoveAnchor() {
        let model = PhotoSelectionModel()
        model.click(3)
        model.toggle(7)
        #expect(model.selected == [3, 7])
        // Anchor stays at the last plain click, not the toggle target.
        #expect(model.anchor == 3)
    }

    @Test func cmdToggleOnSelectedIndexRemovesOnlyThatIndex() {
        let model = PhotoSelectionModel()
        model.click(3)
        model.toggle(7)
        model.toggle(3)
        #expect(model.selected == [7])
    }

    @Test func shiftClickSelectsInclusiveRangeFromAnchor() {
        let model = PhotoSelectionModel()
        model.click(2)
        model.shiftClick(6)
        #expect(model.selected == Set(2...6))
    }

    @Test func shiftClickWorksBackwardsFromAnchor() {
        let model = PhotoSelectionModel()
        model.click(8)
        model.shiftClick(4)
        #expect(model.selected == Set(4...8))
    }

    @Test func secondShiftClickRerangesFromSameAnchorRatherThanExtending() {
        let model = PhotoSelectionModel()
        model.click(2)
        model.shiftClick(6)
        model.shiftClick(3)
        // Re-ranges from the anchor (2) to the new index (3), not extended
        // to include 6 as well.
        #expect(model.selected == Set(2...3))
    }

    @Test func shiftClickWithNoAnchorBehavesLikePlainClick() {
        let model = PhotoSelectionModel()
        model.shiftClick(4)
        #expect(model.selected == [4])
        #expect(model.anchor == 4)
    }

    @Test func toggleAfterShiftRangeDoesNotMoveAnchor() {
        let model = PhotoSelectionModel()
        model.click(2)
        model.shiftClick(6)
        model.toggle(6)
        #expect(model.anchor == 2)
    }

    @Test func selectAllSelectsEveryIndexInRangeAndMovesAnchorToEnd() {
        let model = PhotoSelectionModel()
        model.selectAll(count: 5)
        #expect(model.selected == Set(0..<5))
        #expect(model.anchor == 4)
    }

    @Test func selectAllWithZeroCountClearsSelectionAndAnchor() {
        let model = PhotoSelectionModel()
        model.click(2)
        model.selectAll(count: 0)
        #expect(model.isEmpty)
        #expect(model.anchor == nil)
    }

    @Test func clearEmptiesSelectionButKeepsAnchor() {
        let model = PhotoSelectionModel()
        model.click(4)
        model.toggle(6)
        model.clear()
        #expect(model.isEmpty)
        #expect(model.anchor == 4)
    }

    @Test func isSelectedReflectsCurrentSet() {
        let model = PhotoSelectionModel()
        model.click(1)
        model.toggle(3)
        #expect(model.isSelected(1))
        #expect(model.isSelected(3))
        #expect(!model.isSelected(2))
    }

    @Test func sortedIndicesIsDeterministicRegardlessOfInsertionOrder() {
        let model = PhotoSelectionModel()
        model.click(9)
        model.toggle(2)
        model.toggle(5)
        #expect(model.sortedIndices == [2, 5, 9])
    }
}
