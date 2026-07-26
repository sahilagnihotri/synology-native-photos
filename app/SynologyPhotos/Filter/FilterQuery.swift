import Foundation
import PhotosCore

/// The compound Quick Filter the library grid pages against: a file-type
/// facet, an inclusive `taken_at` date range (unix seconds), a minimum star
/// rating, and the two server-side cluster facets (a People `personId` and a
/// Geolocation `geocodingId`). Every facet is optional; a `nil` facet imposes
/// no constraint, so `FilterQuery()` (every facet `nil`) means "no filter" and
/// behaves exactly like the plain library grid.
///
/// TWO ROUTES, decided by `usesServerFilter`:
/// - File type, date range, and rating are LOCAL-index columns
///   (`media_kind`, `taken_at`, `rating`) and map one-for-one onto
///   `PhotosCore.filterAssets`/`filterCount` with no translation layer.
/// - People (`personId`) and Geolocation (`geocodingId`) are SERVER-side
///   Browse.Item clusters with no local-index column, so when either is set the
///   grid must run a live remote fetch (`filterItemsRemote`) instead. File type
///   and rating do NOT combine with a server filter (the NAS `type` param is
///   unreliable, and rating is local only); only person/geo + the date range go
///   to the server. The date range combines in BOTH routes.
///
/// Favorites is deliberately not represented: there is no API read path for it
/// on this NAS.
struct FilterQuery: Equatable, Hashable {
    var mediaKind: MediaKind?
    var takenAfter: Int64?
    var takenBefore: Int64?
    var minRating: UInt8?
    /// A People cluster id from `SYNO.Foto.Browse.Person` (server-side filter).
    var personId: Int64?
    /// A Geolocation cluster id from `SYNO.Foto.Browse.Geocoding` (server-side
    /// filter). Must come from that API, not Search.Filter (different id
    /// namespace).
    var geocodingId: Int64?

    /// The neutral, unconstrained query: identical to showing the plain
    /// library. `isActive` is false for this value.
    static let none = FilterQuery()

    /// Whether any facet is set. Drives whether applying the filter does
    /// anything and whether the filter bar shows its active (filled) icon.
    var isActive: Bool {
        mediaKind != nil || takenAfter != nil || takenBefore != nil || minRating != nil
            || personId != nil || geocodingId != nil
    }

    /// True when the built filter must run SERVER-side, i.e. a People or
    /// Geolocation facet is set. The data source routes a server filter to a
    /// live `filterItemsRemote` window (person/geo + date only); everything
    /// else stays on the local `filterAssets` path. File type and rating are
    /// ignored on the server route, which is why the UI disables those controls
    /// while a person/place is chosen.
    var usesServerFilter: Bool {
        personId != nil || geocodingId != nil
    }

    /// A short, human-readable summary for the grid header while the filter is
    /// active, e.g. "Videos, 3+ Stars" (local route) or "Place, Date" (server
    /// route). Only the facets that actually apply on the active route are
    /// listed, so the header never advertises a file-type/rating facet that a
    /// server filter silently ignores. Empty when nothing is set.
    var summary: String {
        var parts: [String] = []
        if usesServerFilter {
            if personId != nil { parts.append("People") }
            if geocodingId != nil { parts.append("Place") }
            if takenAfter != nil || takenBefore != nil { parts.append("Date") }
            return parts.joined(separator: ", ")
        }
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
