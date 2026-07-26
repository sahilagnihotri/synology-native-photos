import Testing
import AppKit
@testable import MySynologyPhotos

/// Exercises the pure key-event-to-action mapping behind the detail viewer's
/// keyboard map, independent of any live `NSResponder`. Mirrors
/// `GridKeyActionTests`; the case that matters most for this pass is that
/// Delete reaches the viewer at all, so full-photo delete works.
struct DetailKeyActionTests {
    private func event(keyCode: UInt16, command: Bool = false) -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
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

    @Test func deleteAndForwardDeleteMapToDeleteRegardlessOfCommand() {
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.delete)) == .delete)
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.forwardDelete)) == .delete)
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.delete, command: true)) == .delete)
    }

    @Test func escapeSpaceAndCmdUpAllClose() {
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.escape)) == .close)
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.space)) == .close)
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.upArrow, command: true)) == .close)
    }

    @Test func leftAndRightPage() {
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.leftArrow)) == .previous)
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.rightArrow)) == .next)
    }

    @Test func cmdITogglesInfoButPlainIDoesNot() {
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.i, command: true)) == .toggleInfo)
        #expect(DetailKeyMapper.action(for: event(keyCode: KeyCode.i)) == nil)
    }

    @Test func unrecognizedKeyMapsToNil() {
        #expect(DetailKeyMapper.action(for: event(keyCode: 0xFF)) == nil)
    }
}
