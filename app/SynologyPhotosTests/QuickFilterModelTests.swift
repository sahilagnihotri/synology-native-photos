import Testing
import Foundation
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct QuickFilterModelTests {
    @Test func startsWithNoActiveFilter() {
        let model = QuickFilterModel()
        #expect(model.hasActiveFilter == false)
        #expect(model.currentQuery == FilterQuery.none)
        #expect(model.currentQuery.isActive == false)
    }

    @Test func fileTypeMapsToTheMediaKindField() {
        let model = QuickFilterModel()
        model.mediaKind = .video
        let query = model.currentQuery
        #expect(query.mediaKind == .video)
        // No other facet is touched by choosing a file type.
        #expect(query.takenAfter == nil)
        #expect(query.takenBefore == nil)
        #expect(query.minRating == nil)
        #expect(model.hasActiveFilter)
    }

    @Test func ratingMapsToTheMinRatingField() {
        let model = QuickFilterModel()
        model.minRating = 3
        let query = model.currentQuery
        #expect(query.minRating == 3)
        #expect(query.mediaKind == nil)
        #expect(model.hasActiveFilter)
    }

    @Test func dateRangeMapsToStartOfDayFloorAndEndOfDayCeiling() {
        let model = QuickFilterModel()
        let calendar = Calendar.current
        let start = calendar.date(from: DateComponents(year: 2020, month: 6, day: 15, hour: 9, minute: 30))!
        let end = calendar.date(from: DateComponents(year: 2020, month: 6, day: 20, hour: 18, minute: 45))!
        model.startDate = start
        model.endDate = end

        let query = model.currentQuery
        let expectedAfter = Int64(calendar.startOfDay(for: start).timeIntervalSince1970)
        let endOfDay = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: end))!
        let expectedBefore = Int64(endOfDay.timeIntervalSince1970)
        #expect(query.takenAfter == expectedAfter)
        #expect(query.takenBefore == expectedBefore)
        // A same-or-forward range always has a floor strictly before the ceiling.
        #expect(query.takenAfter! < query.takenBefore!)
        #expect(model.hasActiveFilter)
    }

    @Test func allThreeFacetsCombineIntoOneQuery() {
        let model = QuickFilterModel()
        model.mediaKind = .photo
        model.minRating = 4
        model.startDate = Date(timeIntervalSince1970: 1_500_000_000)
        let query = model.currentQuery
        #expect(query.mediaKind == .photo)
        #expect(query.minRating == 4)
        #expect(query.takenAfter != nil)
        #expect(query.takenBefore == nil, "an unset upper bound stays nil")
        #expect(model.hasActiveFilter)
    }

    @Test func clearResetsEveryFacet() {
        let model = QuickFilterModel()
        model.mediaKind = .video
        model.minRating = 5
        model.startDate = Date()
        model.endDate = Date()
        model.personId = 12
        model.geocodingId = 768
        #expect(model.hasActiveFilter)

        model.clear()
        #expect(model.hasActiveFilter == false)
        #expect(model.currentQuery == FilterQuery.none)
        #expect(model.mediaKind == nil)
        #expect(model.minRating == nil)
        #expect(model.startDate == nil)
        #expect(model.endDate == nil)
        #expect(model.personId == nil)
        #expect(model.geocodingId == nil)
    }

    // MARK: - People / Geolocation (server-side) facets

    @Test func aPlainLocalFilterDoesNotUseTheServerRoute() {
        let model = QuickFilterModel()
        model.mediaKind = .photo
        model.minRating = 3
        #expect(model.currentQuery.isActive)
        #expect(model.currentQuery.usesServerFilter == false)
        #expect(model.usesServerFilter == false)
    }

    @Test func selectingAPersonRoutesServerSideAndMapsTheId() {
        let model = QuickFilterModel()
        model.personId = 12279
        let query = model.currentQuery
        #expect(query.personId == 12279)
        #expect(query.geocodingId == nil)
        #expect(query.usesServerFilter, "a People facet forces the server route")
        #expect(model.usesServerFilter)
        #expect(model.hasActiveFilter)
    }

    @Test func selectingAPlaceRoutesServerSideAndMapsTheId() {
        let model = QuickFilterModel()
        model.geocodingId = 768
        let query = model.currentQuery
        #expect(query.geocodingId == 768)
        #expect(query.personId == nil)
        #expect(query.usesServerFilter, "a Geolocation facet forces the server route")
        #expect(model.usesServerFilter)
    }

    @Test func personGeoAndDateAllMapThroughToTheServerQuery() {
        let model = QuickFilterModel()
        model.personId = 42
        model.geocodingId = 768
        model.startDate = Date(timeIntervalSince1970: 1_400_000_000)
        let query = model.currentQuery
        #expect(query.personId == 42)
        #expect(query.geocodingId == 768)
        #expect(query.takenAfter != nil, "the date range combines on the server route too")
        #expect(query.usesServerFilter)
        // The header summary only lists facets that actually apply on the
        // server route (People, Place, Date), never file type / rating.
        #expect(query.summary == "People, Place, Date")
    }

    @Test func serverRouteSummaryOmitsIgnoredFileTypeAndRating() {
        let model = QuickFilterModel()
        model.mediaKind = .video
        model.minRating = 5
        model.geocodingId = 768
        // File type + rating are set but ignored on the server route, so the
        // summary must not advertise them.
        #expect(model.currentQuery.summary == "Place")
    }

    @Test func loadFacetsPopulatesPeopleAndPlacesFromTheCore() async {
        let fake = FakePhotosCore()
        fake.peopleResult = .success([
            Person(id: 12279, name: "", itemCount: 23, coverUnitId: 39646, show: true),
            Person(id: 12285, name: "Sahil", itemCount: 8, coverUnitId: 39727, show: true),
        ])
        fake.placesResult = .success([
            Place(id: 768, name: "Grunerlokka, Oslo", country: "Norway",
                  firstLevel: "Oslo", secondLevel: "Grunerlokka", itemCount: 10),
        ])
        let model = QuickFilterModel()
        #expect(model.facetsLoaded == false)

        await model.loadFacets(using: PhotosCoreClient(core: fake))
        #expect(model.facetsLoaded)
        #expect(model.people.count == 2)
        #expect(model.people.first?.id == 12279)
        #expect(model.places.count == 1)
        #expect(model.places.first?.name == "Grunerlokka, Oslo")
        #expect(fake.fetchPeopleCallCount == 1)
        #expect(fake.fetchPlacesCallCount == 1)
    }

    @Test func loadFacetsLeavesEmptyListsWhenTheAccountHasNoClusters() async {
        // This account has 0 people and (here) 0 places: both lists load
        // cleanly as empty, which the popover renders as "No conditions
        // available", never an error.
        let fake = FakePhotosCore()
        let model = QuickFilterModel()
        await model.loadFacets(using: PhotosCoreClient(core: fake))
        #expect(model.facetsLoaded)
        #expect(model.people.isEmpty)
        #expect(model.places.isEmpty)
    }
}
