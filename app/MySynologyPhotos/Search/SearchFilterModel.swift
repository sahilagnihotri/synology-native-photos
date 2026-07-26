import Foundation
import PhotosCore

/// Owns the search facet catalog (loaded once per session, on demand) and
/// the currently selected date range for the filter bar attached to the
/// library's search field.
///
/// Read-only, no saved filters/searches per the brief: this model only ever
/// holds the current in-memory selection, never persists it. Clearing the
/// filter (or the keyword, handled by the caller) simply drops this state
/// and the grid returns to whatever the sidebar was already showing.
///
/// Camera/aperture/location facets are exposed here for the UI to browse
/// and label, but there is deliberately no way to select one as a filter:
/// see `models::Facet`'s doc comment for the probe that found no working
/// filter param for any of them on this NAS. Only the date range is a real,
/// working filter (`start_time`/`end_time`), so that is the only selection
/// this model tracks.
@MainActor
@Observable
final class SearchFilterModel {
    private let client: PhotosCoreClient

    private(set) var facets: SearchFacets?
    private(set) var isLoadingFacets = false
    private(set) var loadError: String?

    /// The user's selected start of the date range, inclusive. `nil` means
    /// no lower bound.
    var startDate: Date?
    /// The user's selected end of the date range, inclusive. `nil` means no
    /// upper bound.
    var endDate: Date?

    init(client: PhotosCoreClient) {
        self.client = client
    }

    /// Whether any filter is currently active. Drives whether the filter
    /// bar shows a "Clear" affordance and whether the grid should route
    /// through a filtered search rather than a plain keyword one.
    var hasActiveFilter: Bool {
        startDate != nil || endDate != nil
    }

    /// The current selection as the `SearchFilters` the core understands:
    /// a start-of-day `startDate` and an end-of-day `endDate`, both in unix
    /// seconds. Using start/end of day (rather than the exact instant the
    /// user's date picker component defaults to, which is midnight for both)
    /// means a one-sided range still covers the whole day it names, and a
    /// same-day range covers that entire day rather than a zero-width
    /// instant.
    var currentFilters: SearchFilters {
        let calendar = Calendar.current
        let start = startDate.map { calendar.startOfDay(for: $0) }
        let end = endDate.map { date -> Date in
            let startOfDay = calendar.startOfDay(for: date)
            return calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfDay) ?? date
        }
        return SearchFilters(
            startTime: start.map { Int64($0.timeIntervalSince1970) },
            endTime: end.map { Int64($0.timeIntervalSince1970) }
        )
    }

    /// Clears the selected date range. Does not touch `facets`: the catalog
    /// stays loaded so reopening the filter popover does not re-fetch it.
    func clear() {
        startDate = nil
        endDate = nil
    }

    /// Loads the facet catalog if it has not been loaded yet (or the prior
    /// load failed). Safe to call every time the filter popover opens: a
    /// second call while `facets` is already populated is a no-op, so
    /// reopening the popover never re-fetches.
    func loadFacetsIfNeeded() async {
        guard facets == nil else { return }
        isLoadingFacets = true
        loadError = nil
        do {
            facets = try await client.fetchSearchFacets()
        } catch let error as CoreError {
            loadError = error.userMessage
        } catch {
            loadError = error.localizedDescription
        }
        isLoadingFacets = false
    }
}
