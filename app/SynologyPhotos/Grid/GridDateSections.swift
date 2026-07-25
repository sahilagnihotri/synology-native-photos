import Foundation
import PhotosCore

/// Identity for a grid section in the diffable data source.
///
/// The space-backed library grid is split into one `.day` section per calendar
/// day, each carrying the histogram's `dayStart`. Every other grid (a
/// discovery collection, a search, or a space whose histogram has not loaded
/// yet) uses the single `.flat` section, which reproduces the original
/// unsectioned layout exactly.
enum GridSectionID: Hashable {
    case flat
    case day(Int64)
}

/// Pure date-section geometry derived from the core's `[DayCount]` histogram.
///
/// Turns the newest-first per-day counts into sections that each know their
/// base absolute index (the running prefix sum of every newer section's
/// count), and maps both ways between a grid `(section, item)` coordinate and
/// the flat absolute index that `WindowedDataSource`/`fetch_assets` page by.
/// Every lookup is O(1) or O(log n); nothing here loads an asset, which is
/// what keeps sectioning lazy at 100k. Kept free of AppKit so the arithmetic
/// is directly unit-testable.
///
/// The histogram's ordering invariant (documented on the core's
/// `date_histogram`) is what makes this mapping correct: section `s`, row `r`
/// is exactly the `base(s) + r`-th row `fetch_assets` returns, so a cell can
/// resolve its asset through the existing windowed data source by that
/// absolute index without the sections ever needing the rows themselves.
struct GridDateSections: Equatable {
    struct Section: Equatable {
        /// The histogram bucket's day start (unix seconds at UTC midnight), or
        /// 0 for the trailing Unknown Date bucket.
        let dayStart: Int64
        /// Number of items in this section.
        let count: Int
        /// Absolute index of this section's first item (prefix sum of the
        /// counts of every newer section).
        let base: Int
    }

    let sections: [Section]
    /// Total item count across every section: equal to the sum of the section
    /// counts, which the core guarantees equals `asset_count(space)`.
    let totalCount: Int

    init(histogram: [DayCount]) {
        var built: [Section] = []
        built.reserveCapacity(histogram.count)
        var running = 0
        for bucket in histogram {
            let count = Int(bucket.count)
            built.append(Section(dayStart: bucket.dayStart, count: count, base: running))
            running += count
        }
        self.sections = built
        self.totalCount = running
    }

    var isEmpty: Bool { sections.isEmpty }

    /// The flat absolute index for a `(section, item)` position, or `nil` when
    /// the coordinate is out of range.
    func absoluteIndex(section: Int, item: Int) -> Int? {
        guard section >= 0, section < sections.count else { return nil }
        let s = sections[section]
        guard item >= 0, item < s.count else { return nil }
        return s.base + item
    }

    /// The `(section, item)` position for a flat absolute index, or `nil` when
    /// it is out of range. Binary search over the (ascending) section bases.
    func position(forAbsolute absolute: Int) -> (section: Int, item: Int)? {
        guard absolute >= 0, absolute < totalCount else { return nil }
        var lo = 0
        var hi = sections.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let s = sections[mid]
            if absolute < s.base {
                hi = mid - 1
            } else if absolute >= s.base + s.count {
                lo = mid + 1
            } else {
                return (mid, absolute - s.base)
            }
        }
        return nil
    }

    /// The section index containing `absolute`, or `nil` when out of range.
    func section(forAbsolute absolute: Int) -> Int? {
        position(forAbsolute: absolute)?.section
    }

    /// The day start (unix seconds) of the section containing `absolute`, or
    /// `nil` when out of range. Used by the scroll scrubber to name the date
    /// of the topmost visible cell.
    func dayStart(forAbsolute absolute: Int) -> Int64? {
        guard let index = section(forAbsolute: absolute) else { return nil }
        return sections[index].dayStart
    }
}

/// Formats a histogram `dayStart` (unix seconds at UTC midnight, or 0 for the
/// Unknown Date bucket) for the date-section header and the scroll scrubber.
///
/// Rendering is done in UTC to match the histogram's own UTC-day bucketing, so
/// the label names the same calendar day the section actually groups; a
/// local-time render could name the neighbouring day for a photo taken near
/// midnight and no longer match its bucket. `en_US_POSIX` keeps the output
/// stable and testable rather than varying with the run's locale.
enum DateSectionFormatter {
    static let unknownDateTitle = "Unknown Date"

    /// A full header title, e.g. "25 November 2016". A `dayStart` of 0 is the
    /// Unknown Date bucket.
    static func headerTitle(dayStart: Int64) -> String {
        guard dayStart != 0 else { return unknownDateTitle }
        return headerFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(dayStart)))
    }

    /// The compact scrubber label, year then month, e.g. "2016 / 11". A
    /// `dayStart` of 0 is the Unknown Date bucket.
    static func scrubberLabel(dayStart: Int64) -> String {
        guard dayStart != 0 else { return unknownDateTitle }
        return scrubberFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(dayStart)))
    }

    private static let headerFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let scrubberFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy / MM"
        return f
    }()
}
