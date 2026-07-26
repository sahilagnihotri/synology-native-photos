import Testing
@testable import MySynologyPhotos

/// Exercises the pure index arithmetic behind detail-viewer Left/Right
/// paging: no wraparound, clamped at both ends.
struct DetailPagingModelTests {
    @Test func indexAfterAdvancesByOneWhenInRange() {
        #expect(DetailPagingModel.index(after: 3, count: 10) == 4)
    }

    @Test func indexAfterAtLastReturnsNil() {
        #expect(DetailPagingModel.index(after: 9, count: 10) == nil)
    }

    @Test func indexBeforeGoesBackByOneWhenInRange() {
        #expect(DetailPagingModel.index(before: 3) == 2)
    }

    @Test func indexBeforeAtFirstReturnsNil() {
        #expect(DetailPagingModel.index(before: 0) == nil)
    }

    @Test func indexAfterOnEmptyCollectionReturnsNil() {
        #expect(DetailPagingModel.index(after: 0, count: 0) == nil)
    }
}
