import Foundation
import Observation

/// Multi-select state for the photo grid, kept as pure index-set logic with
/// no AppKit dependency so the click/shift/cmd transitions are directly
/// testable and so future delete/album actions have a clean model to read
/// (per the design brief) rather than reaching into `NSCollectionView`'s own
/// selection set.
///
/// Indices are absolute row positions in the grid's current single section,
/// matching what `PhotoGridController`/`WindowedDataSource` already use
/// elsewhere. `anchor` is the last plain (non-modified) click, the reference
/// point shift-click range-selects from, mirroring Finder/Photos: clicking
/// once sets both the anchor and the selection to that one row; a later
/// shift-click selects the whole range between the anchor and the new row,
/// regardless of how many plain or cmd-clicks happened in between (the
/// anchor only moves on a plain click, never on cmd-toggle or shift-range).
@MainActor
@Observable
final class PhotoSelectionModel {
    private(set) var selected: Set<Int> = []
    private(set) var anchor: Int?

    init() {}

    var count: Int { selected.count }
    var isEmpty: Bool { selected.isEmpty }

    func isSelected(_ index: Int) -> Bool { selected.contains(index) }

    /// Plain click: selects exactly `index`, replacing any previous
    /// selection, and moves the anchor to it.
    func click(_ index: Int) {
        selected = [index]
        anchor = index
    }

    /// Cmd-click: toggles `index` in/out of the selection without touching
    /// the rest. Per Finder/Photos convention, the anchor does not move (a
    /// following shift-click still ranges from the last plain click, not
    /// from this toggle).
    func toggle(_ index: Int) {
        if selected.contains(index) {
            selected.remove(index)
        } else {
            selected.insert(index)
        }
    }

    /// Shift-click: selects every index between the anchor and `index`
    /// inclusive, replacing the previous selection (matching Finder/Photos:
    /// a second shift-click re-ranges from the same anchor, it does not
    /// extend an already-extended range). If there is no anchor yet (first
    /// click in a fresh selection was itself a shift-click), this behaves
    /// like a plain click and sets the anchor.
    func shiftClick(_ index: Int) {
        guard let anchor else {
            click(index)
            return
        }
        let range = anchor <= index ? anchor...index : index...anchor
        selected = Set(range)
    }

    /// Cmd-A: selects every index in `0..<count`. The anchor moves to the
    /// last index so a following shift-click ranges from the end, matching
    /// how Photos behaves after Select All.
    func selectAll(count: Int) {
        guard count > 0 else {
            selected = []
            anchor = nil
            return
        }
        selected = Set(0..<count)
        anchor = count - 1
    }

    /// Clears the selection (e.g. Escape, or a click on empty space).
    /// Leaves the anchor as-is: Escape is a common Photos/Finder undo-ish
    /// gesture, and clearing the anchor too would make a follow-up
    /// shift-click behave like a fresh plain click instead of resuming from
    /// where the user last was.
    func clear() {
        selected = []
    }

    /// A stable, sorted view of the current selection, for callers (the
    /// toolbar count, keyboard navigation) that need a deterministic order
    /// rather than the set's arbitrary iteration order.
    var sortedIndices: [Int] { selected.sorted() }
}
