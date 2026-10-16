import SwiftUI
import PhotosCore

/// Fetches and caches discovery-tile cover thumbnails (Person and Album
/// covers; Places/Subjects/Tags carry no cover on the real NAS).
///
/// Deliberately separate from `ThumbnailCache`: that cache's composite key
/// requires a real `cache_key`, but `SYNO.Foto.Browse.Person` returns only
/// a bare `cover` unit_id with no accompanying cache_key (verified against
/// the real NAS). This cache keys on unit_id alone and passes an empty
/// cache_key to the core's `thumbnail` call when the caller has none, which
/// is exactly what the `Person.coverUnitId` doc comment on the core side
/// documents as the expected way to fetch it. An Album cover does carry a
/// real `cover_cache_key` (from `additional.thumbnail.cache_key`), which is
/// passed through when available so its cache invalidation matches every
/// other thumbnail fetch in the app rather than being pinned to unit_id
/// alone.
///
/// Small and unbounded-by-design: a person/place/album list is expected to
/// be at most a few hundred rows, nowhere near the scale that motivated
/// `ThumbnailCache`'s byte-budgeted `NSCache`, so a plain dictionary is
/// enough here.
actor DiscoveryCoverCache {
    private let client: PhotosCoreClient
    private var memory: [Int64: Image] = [:]

    init(client: PhotosCoreClient) {
        self.client = client
    }

    /// Resolves a `SwiftUI.Image` for the cover at `unitId` (Personal space
    /// only: discovery browse is personal-space-only for this pass), using
    /// `cacheKey` when the caller has one (Album covers) or an empty string
    /// when it does not (Person covers, which carry no cache_key at all).
    /// Returns `nil` on any failure (missing thumbnail, no session, network
    /// error) so the tile view can fall back to its glyph placeholder
    /// rather than propagate an error for what is, from the user's point of
    /// view, just a missing photo.
    func cover(unitId: Int64, cacheKey: String = "") async -> Image? {
        if let hit = memory[unitId] { return hit }
        do {
            let data = try await client.thumbnail(space: .personal, unitId: unitId, cacheKey: cacheKey, size: .m)
            guard let nsImage = NSImage(data: data.bytes) else { return nil }
            let image = Image(nsImage: nsImage)
            memory[unitId] = image
            return image
        } catch {
            return nil
        }
    }
}
