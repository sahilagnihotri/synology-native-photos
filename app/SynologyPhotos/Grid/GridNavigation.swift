import Foundation

/// Pure index arithmetic behind Left/Right/Up/Down navigation, kept free of
/// `NSCollectionView` so the row math is directly testable.
///
/// The grid is a single flowing section (see `PhotoGridController`), so
/// "next row" is just "current index + itemsPerRow", clamped to
/// `0..<count`. Left/Right at the very first/last item intentionally do not
/// wrap (matches Photos: pressing Left on the first photo does nothing,
/// rather than jumping to the last one).
enum GridNavigation {
    /// How many whole items fit across `availableWidth` given `itemSize`
    /// and the fixed inter-item gap, matching the flow layout's own
    /// wrapping math. Always at least 1 so a very narrow window (or a very
    /// large zoom level) still has a well-defined "next row".
    static func itemsPerRow(availableWidth: CGFloat, itemSize: CGFloat, gap: CGFloat) -> Int {
        guard itemSize > 0 else { return 1 }
        let perRow = Int((availableWidth + gap) / (itemSize + gap))
        return max(perRow, 1)
    }

    /// The current focus index to act on (open detail, QuickLook, arrow
    /// navigation origin), clamped to the applied snapshot's `count`, or
    /// `nil` when there is nothing valid to act on. A `candidate` from a
    /// selection made in a larger space can outlive a switch to a smaller
    /// one; returning it unclamped would open the detail viewer on a stale,
    /// out-of-range row. Bounding against the applied count (never the data
    /// source's total) keeps every keyboard path safe.
    static func clampedCurrent(_ candidate: Int?, count: Int) -> Int? {
        guard count > 0, let index = candidate, index >= 0, index < count else { return nil }
        return index
    }

    /// The index Left/Right/Up/Down should move focus to, or `nil` if the
    /// move would go out of range (`0..<count`), in which case the caller
    /// should leave the current selection untouched.
    static func target(for action: GridKeyAction, from current: Int, itemsPerRow: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let proposed: Int
        switch action {
        case .previous: proposed = current - 1
        case .next: proposed = current + 1
        case .up: proposed = current - itemsPerRow
        case .down: proposed = current + itemsPerRow
        default: return nil
        }
        guard proposed >= 0, proposed < count else { return nil }
        return proposed
    }
}
