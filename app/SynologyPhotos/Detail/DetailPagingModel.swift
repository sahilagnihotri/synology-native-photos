import Foundation

/// Pure index arithmetic behind the detail viewer's arrow-key paging.
/// Mirrors `GridNavigation.target` for previous/next, kept as its own tiny
/// type since the detail viewer only ever moves one item at a time (no
/// up/down-by-row concept once you are looking at a single photo) and does
/// not need `itemsPerRow`.
///
/// Does not wrap: paging past the first or last item is a no-op, matching
/// Photos' own detail viewer (Left on the first photo, Right on the last,
/// both do nothing).
enum DetailPagingModel {
    static func index(after current: Int, count: Int) -> Int? {
        let next = current + 1
        return next < count ? next : nil
    }

    static func index(before current: Int) -> Int? {
        let previous = current - 1
        return previous >= 0 ? previous : nil
    }
}
