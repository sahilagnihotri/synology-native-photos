import Foundation
import PhotosCore

/// Holds the in-memory selection for the library grid's Quick Filter popover
/// (file type, a date-taken range, a minimum rating, and the People /
/// Geolocation clusters) and maps it to the `FilterQuery` the data source and
/// core understand.
///
/// Read-only, no saved filters per the brief: this only ever holds the current
/// selection, never persists it. Applying builds a `FilterQuery` from
/// `currentQuery`; clearing drops the selection and the grid returns to the
/// plain library.
///
/// Unlike file type / date / rating (which map directly onto local-index
/// columns and need nothing fetched), the People and Geolocation facets are
/// populated from the NAS: `loadFacets` fills `people`/`places` from
/// `fetchPeople`/`fetchPlaces` when the popover opens (this account has 0
/// people and few/one geo region, so the lists are commonly empty, matching
/// Synology's "No conditions available").
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
    /// The selected People cluster id, or `nil` for Any. Selecting one routes
    /// the filter server-side (see `FilterQuery.usesServerFilter`).
    var personId: Int64?
    /// The selected Geolocation cluster id, or `nil` for Any. Also routes the
    /// filter server-side.
    var geocodingId: Int64?

    /// The People clusters offered in the popover, loaded from the NAS. Empty
    /// until `loadFacets` runs (and commonly empty afterward on this account).
    private(set) var people: [Person] = []
    /// The Geolocation clusters offered in the popover, loaded from the NAS.
    private(set) var places: [Place] = []
    /// Whether `loadFacets` has completed at least once, so the popover can
    /// tell "still loading" apart from "loaded, but genuinely empty".
    private(set) var facetsLoaded = false

    init() {}

    /// Whether any facet is currently selected. Drives the filter bar's active
    /// (filled) icon and whether Apply does anything.
    var hasActiveFilter: Bool { currentQuery.isActive }

    /// Whether a server-side (People/Geolocation) facet is selected, so the
    /// popover can disable the file-type and rating controls (which do not
    /// combine with a server filter) and show the explanatory hint.
    var usesServerFilter: Bool { personId != nil || geocodingId != nil }

    /// Loads the People and Geolocation cluster lists from the NAS for the
    /// popover to offer. Called when the popover opens. Each list fails soft to
    /// empty (shown as "No conditions available") so a fetch error never blocks
    /// the rest of the filter; `facetsLoaded` flips true once both attempts
    /// finish regardless of outcome.
    func loadFacets(using client: PhotosCoreClient) async {
        people = (try? await client.fetchPeople(offset: 0, limit: 1000)) ?? []
        places = (try? await client.fetchPlaces(offset: 0, limit: 1000)) ?? []
        facetsLoaded = true
    }

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
            minRating: minRating,
            personId: personId,
            geocodingId: geocodingId
        )
    }

    /// Clears every facet back to All / no range, so the next Apply returns to
    /// the plain library. The loaded `people`/`places` lists are kept (they are
    /// catalog data, not a selection) so a cleared popover still offers them.
    func clear() {
        mediaKind = nil
        minRating = nil
        startDate = nil
        endDate = nil
        personId = nil
        geocodingId = nil
    }
}
