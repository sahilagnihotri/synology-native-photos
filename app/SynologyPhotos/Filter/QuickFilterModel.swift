import Foundation
import PhotosCore

/// Holds the in-memory selection for the library grid's Quick Filter popover
/// (file type, a date-taken range, and a minimum rating) and maps it to the
/// `FilterQuery` the data source and core understand.
///
/// Read-only, no saved filters per the brief: this only ever holds the
/// current selection, never persists it. Applying builds a `FilterQuery` from
/// `currentQuery`; clearing drops the selection and the grid returns to the
/// plain library. It needs no client of its own: unlike `SearchFilterModel`
/// (which loads a facet catalog over the network) every facet here maps
/// directly onto a local-index column, so there is nothing to fetch.
@MainActor
@Observable
final class QuickFilterModel {
    /// The file-type selection. `nil` means All (no file-type constraint);
    /// `MediaKind.unknown` is never offered in the UI.
    var mediaKind: MediaKind?
    /// The "at least this many stars" floor, 1...5, or `nil` for All (any
    /// rating, including unrated).
    var minRating: UInt8?
    /// The user's selected start of the date range, inclusive. `nil` means no
    /// lower bound.
    var startDate: Date?
    /// The user's selected end of the date range, inclusive. `nil` means no
    /// upper bound.
    var endDate: Date?

    init() {}

    /// Whether any facet is currently selected. Drives the filter bar's active
    /// (filled) icon and whether Apply does anything.
    var hasActiveFilter: Bool { currentQuery.isActive }

    /// Maps the current UI selection to the `FilterQuery` the data source and
    /// core understand. The date range uses start-of-day for the floor and
    /// end-of-day for the ceiling (rather than the picker's default midnight
    /// instant), so a one-sided or same-day range still covers the whole day
    /// it names, matching `SearchFilterModel.currentFilters`.
    var currentQuery: FilterQuery {
        let calendar = Calendar.current
        let after = startDate.map { calendar.startOfDay(for: $0) }
        let before = endDate.map { date -> Date in
            let startOfDay = calendar.startOfDay(for: date)
            return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) ?? date
        }
        return FilterQuery(
            mediaKind: mediaKind,
            takenAfter: after.map { Int64($0.timeIntervalSince1970) },
            takenBefore: before.map { Int64($0.timeIntervalSince1970) },
            minRating: minRating
        )
    }

    /// Clears every facet back to All / no range, so the next Apply returns to
    /// the plain library.
    func clear() {
        mediaKind = nil
        minRating = nil
        startDate = nil
        endDate = nil
    }
}
