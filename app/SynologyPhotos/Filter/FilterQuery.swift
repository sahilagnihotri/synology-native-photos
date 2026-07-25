import Foundation
import PhotosCore

/// The compound, local-index Quick Filter the library grid pages against: a
/// file-type facet, an inclusive `taken_at` date range (unix seconds), and a
/// minimum star rating. Every facet is optional; a `nil` facet imposes no
/// constraint, so `FilterQuery()` (every facet `nil`) means "no filter" and
/// behaves exactly like the plain library grid.
///
/// These are the only facets the LOCAL index carries (`media_kind`,
/// `taken_at`, `rating`). People, Geolocation, and Favorites are deliberately
/// NOT part of this filter: they are server-side clusters that already have
/// their own sidebar destinations (see `DiscoveryCollection`), not local-index
/// columns.
///
/// Maps one-for-one onto `PhotosCore.filterAssets`/`filterCount`'s parameters,
/// so the data source can decompose it into a core call with no translation
/// layer in between.
struct FilterQuery: Equatable, Hashable {
    var mediaKind: MediaKind?
    var takenAfter: Int64?
    var takenBefore: Int64?
    var minRating: UInt8?

    /// The neutral, unconstrained query: identical to showing the plain
    /// library. `isActive` is false for this value.
    static let none = FilterQuery()

    /// Whether any facet is set. Drives whether applying the filter does
    /// anything and whether the filter bar shows its active (filled) icon.
    var isActive: Bool {
        mediaKind != nil || takenAfter != nil || takenBefore != nil || minRating != nil
    }

    /// A short, human-readable summary for the grid header while the filter is
    /// active, e.g. "Videos, 3+ Stars". Empty when nothing is set.
    var summary: String {
        var parts: [String] = []
        switch mediaKind {
        case .some(.photo): parts.append("Photos")
        case .some(.video): parts.append("Videos")
        case .some(.unknown), .none: break
        }
        if takenAfter != nil || takenBefore != nil {
            parts.append("Date")
        }
        if let minRating, minRating > 0 {
            parts.append("\(minRating)+ Stars")
        }
        return parts.joined(separator: ", ")
    }
}
