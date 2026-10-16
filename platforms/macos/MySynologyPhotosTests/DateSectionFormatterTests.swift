import Testing
@testable import MySynologyPhotos

/// The header/scrubber date formatting is pure and UTC-pinned (to match the
/// histogram's own UTC-day bucketing), so it is asserted against fixed epoch
/// constants rather than anything locale/timezone dependent.
struct DateSectionFormatterTests {
    // 1_480_032_000 == 2016-11-25 00:00:00 UTC (a UTC-day boundary).
    private let nov25_2016: Int64 = 1_480_032_000

    @Test func headerTitleFormatsTheUTCDay() {
        #expect(DateSectionFormatter.headerTitle(dayStart: nov25_2016) == "25 November 2016")
    }

    @Test func headerTitleForZeroIsUnknownDate() {
        #expect(DateSectionFormatter.headerTitle(dayStart: 0) == "Unknown Date")
    }

    @Test func scrubberLabelIsYearThenMonth() {
        #expect(DateSectionFormatter.scrubberLabel(dayStart: nov25_2016) == "2016 / 11")
    }

    @Test func scrubberLabelForZeroIsUnknownDate() {
        #expect(DateSectionFormatter.scrubberLabel(dayStart: 0) == "Unknown Date")
    }

    /// A `taken_at` a few seconds past midnight still names that same day (the
    /// bucketing floored it to the day start, so the formatter only ever sees
    /// midnight, but this pins the human-visible mapping regardless).
    @Test func headerTitleIsStableAcrossTheDay() {
        #expect(DateSectionFormatter.headerTitle(dayStart: nov25_2016) == "25 November 2016")
        // The next day's boundary is a different title.
        #expect(DateSectionFormatter.headerTitle(dayStart: nov25_2016 + 86_400) == "26 November 2016")
    }
}
