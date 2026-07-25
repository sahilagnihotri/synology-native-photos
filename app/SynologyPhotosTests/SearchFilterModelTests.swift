import Testing
import Foundation
import PhotosCore
@testable import SynologyPhotos

/// Exercises `SearchFilterModel`'s pure state (active-filter detection,
/// clearing, and the date-to-unix-seconds conversion `currentFilters`
/// does) plus the facet catalog load, all against `FakePhotosCore` so no
/// real NAS or network is involved.
@MainActor
struct SearchFilterModelTests {
    @Test func startsWithNoActiveFilter() {
        let model = SearchFilterModel(client: PhotosCoreClient(core: FakePhotosCore()))
        #expect(model.hasActiveFilter == false)
        #expect(model.currentFilters == SearchFilters(startTime: nil, endTime: nil))
    }

    @Test func settingStartDateMarksFilterActive() {
        let model = SearchFilterModel(client: PhotosCoreClient(core: FakePhotosCore()))
        model.startDate = Date()
        #expect(model.hasActiveFilter == true)
    }

    @Test func settingEndDateMarksFilterActive() {
        let model = SearchFilterModel(client: PhotosCoreClient(core: FakePhotosCore()))
        model.endDate = Date()
        #expect(model.hasActiveFilter == true)
    }

    @Test func clearResetsBothDatesAndActiveFlag() {
        let model = SearchFilterModel(client: PhotosCoreClient(core: FakePhotosCore()))
        model.startDate = Date()
        model.endDate = Date()
        model.clear()
        #expect(model.hasActiveFilter == false)
        #expect(model.startDate == nil)
        #expect(model.endDate == nil)
    }

    /// `currentFilters` must convert a selected start date to the START of
    /// that day (in the system's local calendar, matching the model's own
    /// use of `Calendar.current`), not the exact instant the picker happens
    /// to hold, so a one-sided range still covers the whole day.
    @Test func currentFiltersConvertsStartDateToStartOfDayUnixSeconds() {
        let model = SearchFilterModel(client: PhotosCoreClient(core: FakePhotosCore()))
        let calendar = Calendar.current
        let noon = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 12))!
        model.startDate = noon

        let filters = model.currentFilters
        #expect(filters.startTime != nil)
        let decoded = Date(timeIntervalSince1970: TimeInterval(filters.startTime!))
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: decoded)
        #expect(components.hour == 0)
        #expect(components.minute == 0)
        #expect(components.second == 0)
    }

    /// `currentFilters` must convert a selected end date to the END of that
    /// day (23:59:59, local calendar), so a same-day range covers the whole
    /// day rather than a zero-width instant at midnight.
    @Test func currentFiltersConvertsEndDateToEndOfDayUnixSeconds() {
        let model = SearchFilterModel(client: PhotosCoreClient(core: FakePhotosCore()))
        let calendar = Calendar.current
        let noon = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 12))!
        model.endDate = noon

        let filters = model.currentFilters
        #expect(filters.endTime != nil)
        let decoded = Date(timeIntervalSince1970: TimeInterval(filters.endTime!))
        let components = calendar.dateComponents([.hour, .minute, .second], from: decoded)
        #expect(components.hour == 23)
        #expect(components.minute == 59)
        #expect(components.second == 59)
    }

    @Test func loadFacetsIfNeededPopulatesFromTheCore() async {
        let fake = FakePhotosCore()
        fake.searchFacetsResult = .success(SearchFacets(
            cameras: [Facet(id: 23, name: "iPhone 6s")],
            apertures: [Facet(id: 1, name: "F1.8")],
            geocodings: [Facet(id: 12, name: "Oslo")],
            mediaTypes: [Facet(id: 0, name: "photo")]
        ))
        let model = SearchFilterModel(client: PhotosCoreClient(core: fake))
        await model.loadFacetsIfNeeded()
        #expect(model.facets?.cameras.first?.name == "iPhone 6s")
        #expect(fake.fetchSearchFacetsCallCount == 1)
    }

    /// A second call while facets are already loaded must not re-fetch:
    /// reopening the filter popover should be free once the catalog is in
    /// memory for the session.
    @Test func loadFacetsIfNeededIsANoOpOnceLoaded() async {
        let fake = FakePhotosCore()
        let model = SearchFilterModel(client: PhotosCoreClient(core: fake))
        await model.loadFacetsIfNeeded()
        await model.loadFacetsIfNeeded()
        #expect(fake.fetchSearchFacetsCallCount == 1)
    }

    @Test func loadFacetsIfNeededSurfacesAnErrorAsUserMessage() async {
        let fake = FakePhotosCore()
        fake.searchFacetsResult = .failure(.Network(message: "timed out"))
        let model = SearchFilterModel(client: PhotosCoreClient(core: fake))
        await model.loadFacetsIfNeeded()
        #expect(model.facets == nil)
        #expect(model.loadError != nil)
        #expect(model.isLoadingFacets == false)
    }
}
