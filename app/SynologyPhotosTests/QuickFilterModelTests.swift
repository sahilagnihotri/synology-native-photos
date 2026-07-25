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
        #expect(model.hasActiveFilter)

        model.clear()
        #expect(model.hasActiveFilter == false)
        #expect(model.currentQuery == FilterQuery.none)
        #expect(model.mediaKind == nil)
        #expect(model.minRating == nil)
        #expect(model.startDate == nil)
        #expect(model.endDate == nil)
    }
}
