import AppKit

/// The grid's full keyboard vocabulary, kept as a plain enum so the
/// "which key combination means what" mapping is a pure function testable
/// without any live `NSEvent`/`NSResponder`.
enum GridKeyAction: Equatable {
    case previous
    case next
    case up
    case down
    /// Shift+Left: extend the selection from the anchor to the previous
    /// item, the keyboard equivalent of shift-click. Kept distinct from
    /// `.previous` (not a shift flag riding along on the same case) so
    /// `handleKey` can route it through `PhotoSelectionModel.shiftClick`
    /// instead of `click`, without re-deriving the shift flag from the raw
    /// event a second time.
    case extendPrevious
    case extendNext
    case extendUp
    case extendDown
    case toggleQuickLook
    case openDetail
    case clearSelectionOrClose
    case selectAll
    case delete
}

enum GridKeyMapper {
    /// Maps a raw key event to the action it represents, or `nil` if the
    /// event is not one the grid handles (callers should let it fall
    /// through to the normal responder chain in that case).
    ///
    /// Delete is recognized both as the plain Delete/Backspace key and as
    /// Cmd-Delete, matching the brief's "Delete or Cmd-Delete" wording and
    /// Finder's own convention of accepting either.
    ///
    /// Shift on an arrow key maps to the corresponding `.extend*` action
    /// rather than the plain move action, matching Finder/Photos: holding
    /// Shift while pressing an arrow key extends the selection instead of
    /// replacing it. Shift is checked before the plain arrow cases so it
    /// always wins when held, regardless of Command also being down (there
    /// is no defined Cmd+Shift+Arrow grid behavior, so Shift alone decides).
    static func action(for event: NSEvent) -> GridKeyAction? {
        let command = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        switch event.keyCode {
        case KeyCode.leftArrow: return shift ? .extendPrevious : .previous
        case KeyCode.rightArrow: return shift ? .extendNext : .next
        case KeyCode.upArrow: return shift ? .extendUp : .up
        case KeyCode.downArrow: return shift ? .extendDown : .down
        case KeyCode.space: return .toggleQuickLook
        case KeyCode.returnKey, KeyCode.keypadEnter: return .openDetail
        case KeyCode.escape: return .clearSelectionOrClose
        case KeyCode.delete, KeyCode.forwardDelete: return .delete
        case KeyCode.a where command: return .selectAll
        default: return nil
        }
    }
}

/// Virtual key codes for the keys the grid cares about. `NSEvent.keyCode`
/// is a raw hardware-layout code with no named constants in AppKit for
/// these, so they are spelled out once here rather than as magic numbers
/// scattered through the mapping switch above.
enum KeyCode {
    static let returnKey: UInt16 = 0x24
    static let keypadEnter: UInt16 = 0x4C
    static let escape: UInt16 = 0x35
    static let space: UInt16 = 0x31
    static let delete: UInt16 = 0x33 // Backspace/Delete
    static let forwardDelete: UInt16 = 0x75
    static let leftArrow: UInt16 = 0x7B
    static let rightArrow: UInt16 = 0x7C
    static let downArrow: UInt16 = 0x7D
    static let upArrow: UInt16 = 0x7E
    static let a: UInt16 = 0x00
}
