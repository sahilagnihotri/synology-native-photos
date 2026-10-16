import AppKit

/// The detail viewer's keyboard vocabulary, kept as a plain enum so the
/// "which key means what" mapping is a pure function testable without any
/// live `NSEvent`/`NSResponder`, exactly like the grid's own `GridKeyMapper`.
enum DetailKeyAction: Equatable {
    /// Return to the grid (Escape, Space, or Cmd+Up).
    case close
    /// Page to the previous photo (Left).
    case previous
    /// Page to the next photo (Right).
    case next
    /// Toggle the info panel (Cmd+I).
    case toggleInfo
    /// Delete the currently shown photo (Delete / Forward-Delete, with or
    /// without Command, matching Finder's "Delete or Cmd-Delete"). Routes
    /// into the SAME `DeleteController` confirm the grid uses.
    case delete
}

enum DetailKeyMapper {
    /// Maps a raw key event to the detail-viewer action it represents, or
    /// `nil` if the event is not one the viewer handles (callers let it fall
    /// through to the normal responder chain in that case).
    ///
    /// Space and Cmd+Up both close, mirroring the grid's Cmd+Down "open into
    /// detail". Delete is accepted as the plain Delete/Forward-Delete key and
    /// as Cmd-Delete alike, matching the grid's own delete mapping and
    /// Finder's convention of accepting either.
    static func action(for event: NSEvent) -> DetailKeyAction? {
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case KeyCode.escape: return .close
        case KeyCode.space: return .close
        case KeyCode.upArrow where command: return .close
        case KeyCode.leftArrow: return .previous
        case KeyCode.rightArrow: return .next
        case KeyCode.i where command: return .toggleInfo
        case KeyCode.delete, KeyCode.forwardDelete: return .delete
        default: return nil
        }
    }
}
