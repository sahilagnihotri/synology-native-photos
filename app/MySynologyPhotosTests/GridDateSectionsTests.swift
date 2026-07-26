import Testing
import PhotosCore
@testable import MySynologyPhotos

/// Pure geometry behind date-section headers: prefix sums and the two-way map
/// between a grid `(section, item)` coordinate and the flat absolute index the
/// windowed data source pages by. No AppKit, no data source: this is the math
/// the whole feature relies on, so it is tested directly.
struct GridDateSectionsTests {
    private func day(_ start: Int64, _ count: UInt32) -> DayCount { DayCount(dayStart: start, count: count) }

    @Test func prefixSumsAssignEachSectionItsBase() {
        let s = GridDateSections(histogram: [day(300, 2), day(200, 3), day(100, 1)])
        #expect(s.totalCount == 6)
        #expect(s.sections.map(\.base) == [0, 2, 5])
        #expect(s.sections.map(\.count) == [2, 3, 1])
        #expect(s.sections.map(\.dayStart) == [300, 200, 100])
    }

    @Test func absoluteIndexWalksSectionsInOrder() {
        let s = GridDateSections(histogram: [day(300, 2), day(200, 3), day(100, 1)])
        #expect(s.absoluteIndex(section: 0, item: 0) == 0)
        #expect(s.absoluteIndex(section: 0, item: 1) == 1)
        #expect(s.absoluteIndex(section: 1, item: 0) == 2)
        #expect(s.absoluteIndex(section: 1, item: 2) == 4)
        #expect(s.absoluteIndex(section: 2, item: 0) == 5)
    }

    @Test func absoluteIndexIsNilOutOfRange() {
        let s = GridDateSections(histogram: [day(300, 2)])
        #expect(s.absoluteIndex(section: 0, item: 2) == nil) // past the section's count
        #expect(s.absoluteIndex(section: 1, item: 0) == nil) // no such section
        #expect(s.absoluteIndex(section: -1, item: 0) == nil)
        #expect(s.absoluteIndex(section: 0, item: -1) == nil)
    }

    @Test func positionRoundTripsWithAbsoluteIndexAcrossEveryRow() {
        let s = GridDateSections(histogram: [day(300, 2), day(200, 3), day(100, 1)])
        for absolute in 0..<s.totalCount {
            let pos = s.position(forAbsolute: absolute)
            #expect(pos != nil)
            if let pos {
                #expect(s.absoluteIndex(section: pos.section, item: pos.item) == absolute)
            }
        }
    }

    @Test func positionIsNilOutOfRange() {
        let s = GridDateSections(histogram: [day(300, 2), day(200, 3)])
        #expect(s.position(forAbsolute: -1) == nil)
        #expect(s.position(forAbsolute: 5) == nil)
    }

    @Test func sectionBoundariesMapToTheRightSection() {
        let s = GridDateSections(histogram: [day(300, 2), day(200, 3), day(100, 1)])
        #expect(s.section(forAbsolute: 0) == 0)
        #expect(s.section(forAbsolute: 1) == 0)
        #expect(s.section(forAbsolute: 2) == 1) // first row of section 1
        #expect(s.section(forAbsolute: 4) == 1) // last row of section 1
        #expect(s.section(forAbsolute: 5) == 2) // the single row of section 2
    }

    @Test func dayStartForAbsoluteNamesTheContainingDay() {
        let s = GridDateSections(histogram: [day(300, 2), day(200, 3), day(0, 1)])
        #expect(s.dayStart(forAbsolute: 0) == 300)
        #expect(s.dayStart(forAbsolute: 2) == 200)
        #expect(s.dayStart(forAbsolute: 5) == 0) // the trailing Unknown Date bucket
        #expect(s.dayStart(forAbsolute: 6) == nil)
    }

    @Test func emptyHistogramIsEmpty() {
        let s = GridDateSections(histogram: [])
        #expect(s.isEmpty)
        #expect(s.totalCount == 0)
        #expect(s.position(forAbsolute: 0) == nil)
        #expect(s.section(forAbsolute: 0) == nil)
    }

    /// The single-day case every existing grid test hits (all fixtures share
    /// one `taken_at` day): item index within the one section equals the
    /// absolute index, so the sectioned grid stays a drop-in for the old flat
    /// one there.
    @Test func singleSectionBehavesLikeAFlatRange() {
        let s = GridDateSections(histogram: [day(1_700_000_000, 120)])
        #expect(s.totalCount == 120)
        for i in 0..<120 {
            #expect(s.absoluteIndex(section: 0, item: i) == i)
            #expect(s.position(forAbsolute: i)?.section == 0)
            #expect(s.position(forAbsolute: i)?.item == i)
        }
    }

    /// Binary search must land on the right section even with many buckets of
    /// uneven size, exercised across every absolute index.
    @Test func manyUnevenSectionsMapConsistently() {
        let counts: [UInt32] = [5, 1, 9, 2, 7, 3, 1, 4]
        let hist = counts.enumerated().map { day(Int64(1000 - $0.offset), $0.element) }
        let s = GridDateSections(histogram: hist)
        #expect(s.totalCount == Int(counts.reduce(0, +)))
        for absolute in 0..<s.totalCount {
            let pos = s.position(forAbsolute: absolute)!
            #expect(s.absoluteIndex(section: pos.section, item: pos.item) == absolute)
            // The resolved section's range actually contains the absolute index.
            let sec = s.sections[pos.section]
            #expect(absolute >= sec.base && absolute < sec.base + sec.count)
        }
    }
}
