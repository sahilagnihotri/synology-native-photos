import Testing
import AppKit
@testable import SynologyPhotos

/// Exercises the pure key-event-to-action mapping behind the keyboard map,
/// independent of any live `NSResponder`.
struct GridKeyActionTests {
    private func event(keyCode: UInt16, command: Bool = false, shift: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test func arrowKeysMapToNavigation() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.leftArrow)) == .previous)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.rightArrow)) == .next)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.upArrow)) == .up)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.downArrow)) == .down)
    }

    @Test func shiftArrowKeysMapToExtendActionsNotPlainNavigation() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.leftArrow, shift: true)) == .extendPrevious)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.rightArrow, shift: true)) == .extendNext)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.upArrow, shift: true)) == .extendUp)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.downArrow, shift: true)) == .extendDown)
    }

    @Test func spaceMapsToToggleQuickLook() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.space)) == .toggleQuickLook)
    }

    @Test func returnAndKeypadEnterMapToOpenDetail() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.returnKey)) == .openDetail)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.keypadEnter)) == .openDetail)
    }

    @Test func escapeMapsToClearSelectionOrClose() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.escape)) == .clearSelectionOrClose)
    }

    @Test func deleteAndForwardDeleteMapToDeleteRegardlessOfCommand() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.delete)) == .delete)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.forwardDelete)) == .delete)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.delete, command: true)) == .delete)
    }

    @Test func cmdAMapsToSelectAllButPlainADoesNot() {
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.a, command: true)) == .selectAll)
        #expect(GridKeyMapper.action(for: event(keyCode: KeyCode.a, command: false)) == nil)
    }

    @Test func unrecognizedKeyMapsToNil() {
        #expect(GridKeyMapper.action(for: event(keyCode: 0xFF)) == nil)
    }
}

/// Exercises the pure row/column arithmetic behind Left/Right/Up/Down
/// navigation.
struct GridNavigationTests {
    @Test func itemsPerRowFitsAsManyAsPossible() {
        // 3 items of 100pt with a 4pt gap fit exactly in 312pt (3*100 + 2*4).
        #expect(GridNavigation.itemsPerRow(availableWidth: 312, itemSize: 100, gap: 4) == 3)
    }

    @Test func itemsPerRowNeverGoesBelowOne() {
        #expect(GridNavigation.itemsPerRow(availableWidth: 10, itemSize: 500, gap: 4) == 1)
    }

    @Test func itemsPerRowHandlesZeroItemSizeSafely() {
        #expect(GridNavigation.itemsPerRow(availableWidth: 300, itemSize: 0, gap: 4) == 1)
    }

    @Test func previousAndNextMoveByOne() {
        #expect(GridNavigation.target(for: .previous, from: 5, itemsPerRow: 4, count: 20) == 4)
        #expect(GridNavigation.target(for: .next, from: 5, itemsPerRow: 4, count: 20) == 6)
    }

    @Test func upAndDownMoveByAFullRow() {
        #expect(GridNavigation.target(for: .up, from: 8, itemsPerRow: 4, count: 20) == 4)
        #expect(GridNavigation.target(for: .down, from: 8, itemsPerRow: 4, count: 20) == 12)
    }

    @Test func extendActionsUseTheSameArithmeticAsTheirPlainCounterparts() {
        #expect(GridNavigation.target(for: .extendPrevious, from: 5, itemsPerRow: 4, count: 20) == 4)
        #expect(GridNavigation.target(for: .extendNext, from: 5, itemsPerRow: 4, count: 20) == 6)
        #expect(GridNavigation.target(for: .extendUp, from: 8, itemsPerRow: 4, count: 20) == 4)
        #expect(GridNavigation.target(for: .extendDown, from: 8, itemsPerRow: 4, count: 20) == 12)
    }

    @Test func extendActionsClampAtTheEdgesLikeTheirPlainCounterparts() {
        #expect(GridNavigation.target(for: .extendPrevious, from: 0, itemsPerRow: 4, count: 20) == nil)
        #expect(GridNavigation.target(for: .extendNext, from: 19, itemsPerRow: 4, count: 20) == nil)
    }

    @Test func previousAtFirstIndexReturnsNil() {
        #expect(GridNavigation.target(for: .previous, from: 0, itemsPerRow: 4, count: 20) == nil)
    }

    @Test func nextAtLastIndexReturnsNil() {
        #expect(GridNavigation.target(for: .next, from: 19, itemsPerRow: 4, count: 20) == nil)
    }

    @Test func upPastTheTopRowReturnsNil() {
        #expect(GridNavigation.target(for: .up, from: 2, itemsPerRow: 4, count: 20) == nil)
    }

    @Test func downPastTheLastRowReturnsNil() {
        #expect(GridNavigation.target(for: .down, from: 18, itemsPerRow: 4, count: 20) == nil)
    }

    @Test func zeroCountAlwaysReturnsNil() {
        #expect(GridNavigation.target(for: .next, from: 0, itemsPerRow: 4, count: 0) == nil)
    }

    @Test func nonNavigationActionsReturnNil() {
        #expect(GridNavigation.target(for: .selectAll, from: 0, itemsPerRow: 4, count: 20) == nil)
        #expect(GridNavigation.target(for: .delete, from: 0, itemsPerRow: 4, count: 20) == nil)
    }

    // MARK: clampedCurrent (stale-selection guard)

    @Test func clampedCurrentPassesAnInRangeIndex() {
        #expect(GridNavigation.clampedCurrent(450, count: 500) == 450)
        #expect(GridNavigation.clampedCurrent(0, count: 1) == 0)
    }

    @Test func clampedCurrentRejectsAStaleIndexAfterSwitchingToASmallerSpace() {
        // The reviewer's dead-end scenario: item 450 selected in a 500-item
        // space, then a switch to a 10-item space. Opening detail/QuickLook
        // must NOT act on the stale index.
        #expect(GridNavigation.clampedCurrent(450, count: 10) == nil)
    }

    @Test func clampedCurrentRejectsNilNegativeAndEmpty() {
        #expect(GridNavigation.clampedCurrent(nil, count: 20) == nil)
        #expect(GridNavigation.clampedCurrent(-1, count: 20) == nil)
        #expect(GridNavigation.clampedCurrent(5, count: 0) == nil)
        // The count is an exclusive upper bound.
        #expect(GridNavigation.clampedCurrent(20, count: 20) == nil)
    }
}
