import Foundation
import CoreGraphics
import PhotosCore

/// Composite key for the in-memory tier: an asset alone is not enough because
/// the same asset is requested at several sizes, and a changed `cacheKey`
/// (the core's signal that the underlying bytes changed) must not resolve to
/// a stale decoded image.
struct ThumbKey: Hashable {
    let assetId: Int64
    let size: ThumbnailSize
    let cacheKey: String
}

/// Two-tier thumbnail cache.
///
/// Tier 1 (this type): an in-memory `NSCache` bounded by total byte cost, not
/// item count, so a scroll through a 100k-photo library cannot blow memory
/// regardless of how many distinct thumbnails pass through the viewport.
/// Tier 2 (owned by `PhotosCoreClient`/the Rust core): the on-disk cache
/// behind `ThumbnailData.cachedPath`. This type never manages that disk
/// cache directly, it only asks the core for a path and decodes what comes
/// back.
///
/// Invalidation: the composite `ThumbKey` includes `cacheKey`. When the core
/// reports a new `cacheKey` for an asset (edit, replace, re-crawl), lookups
/// under the old key simply miss and repopulate under the new one; nothing
/// stale is ever handed back to the UI. `invalidate(assetId:)` additionally
/// gives callers an explicit way to drop cached bytes for a specific asset
/// (e.g. after a manual re-fetch); the current implementation performs a
/// full-cache clear, which is correct but coarse, see the task report for
/// the tradeoff.
///
/// Concurrency: this is an `actor` so every read/write against the `NSCache`
/// is serialized through the actor's mailbox, and callers can await
/// `image(space:asset:size:)` freely from the UI without any external
/// locking. The network fetch and the pixel decode both happen off the
/// actor (an `async throws` core call and a `Task.detached` decode) so a
/// slow fetch or a large decode never blocks other cache lookups for
/// different keys, and never blocks the main actor.
actor ThumbnailCache {
    private let client: PhotosCoreClient
    private let memory = NSCache<NSString, CacheBox>()

    /// Boxes a `CGImage` for `NSCache`, which requires its values to be
    /// class instances.
    final class CacheBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// - Parameters:
    ///   - client: the actor-serialized bridge to the Rust core; owns the
    ///     disk cache tier and the network fetch.
    ///   - memoryByteLimit: total decoded-byte budget for tier 1. Defaults
    ///     to 128 MiB, comfortably below typical memory pressure limits
    ///     while holding hundreds of decoded thumbnails at once.
    init(client: PhotosCoreClient, memoryByteLimit: Int = 128 * 1024 * 1024) {
        self.client = client
        memory.totalCostLimit = memoryByteLimit
    }

    /// Maximum pixel dimension ImageIO should downsample to for each
    /// `ThumbnailSize`. Mirrors the grid's real display sizes: `sm` for dense
    /// grid cells, `m` for a slightly larger cell/hover state, `xl` for the
    /// near-fullscreen detail view before falling back to the original.
    static func maxPixel(for size: ThumbnailSize) -> Int {
        switch size {
        case .sm: return 240
        case .m: return 320
        case .xl: return 1280
        // `preview` is only ever used as a fallback for a requested size that
        // is still `converting`; downsample it to the same 1280 ceiling as xl
        // so a grid cell showing it does not decode a needlessly large image.
        case .preview: return 1280
        @unknown default: return 320
        }
    }

    private func nsKey(_ key: ThumbKey) -> NSString {
        Self.nsKey(key)
    }

    private static func nsKey(_ key: ThumbKey) -> NSString {
        "\(key.assetId)|\(key.size)|\(key.cacheKey)" as NSString
    }

    /// Synchronous, non-actor-isolated read of the in-memory tier only.
    ///
    /// `image(space:asset:size:)` is `async` because a miss may need to hop
    /// off the actor for the network fetch and the decode, but a cell that
    /// is simply being re-configured for an asset it might already be
    /// showing cannot afford to await an actor hop just to find out the
    /// answer is "yes, already have it": that await is exactly the gap
    /// where `PhotoCellView` used to blank the image first. `NSCache` is
    /// documented thread-safe for concurrent access, so reading it from
    /// outside the actor's isolation is safe without going through the
    /// actor's mailbox at all. This never touches the disk tier or the
    /// network; a `nil` here only means "not in memory right now", not "does
    /// not exist", and callers should fall back to the async `image(...)`
    /// path on a miss.
    nonisolated func peekMemory(_ key: ThumbKey) -> CGImage? {
        memory.object(forKey: Self.nsKey(key))?.image
    }

    /// Decoded-bytes cost used as the `NSCache` cost for eviction bookkeeping.
    /// `bytesPerRow * height` is the exact size of the decoded bitmap buffer,
    /// which is what actually occupies memory (not the compressed file size).
    private static func byteCost(_ image: CGImage) -> Int {
        image.bytesPerRow * image.height
    }

    /// Resolves a decoded thumbnail for `asset` at `size` within `space`.
    ///
    /// Order of operations: check the in-memory tier under the composite
    /// key; on a hit, return immediately without touching the core at all.
    /// On a miss, ask the core (which itself owns the on-disk cache and the
    /// network fetch), decode the returned bytes off the actor via
    /// `ImageDownsample`, populate the in-memory tier with the decode's
    /// byte cost, and return the decoded image. Any core error (including a
    /// missing/unreadable file) yields `nil` rather than throwing, since a
    /// thumbnail miss during scroll is a normal, recoverable UI event (the
    /// grid cell can show a placeholder), not a fatal condition.
    func image(space: Space, asset: Asset, size: ThumbnailSize) async -> CGImage? {
        let key = ThumbKey(assetId: asset.id, size: size, cacheKey: asset.cacheKey)
        if let hit = memory.object(forKey: nsKey(key)) {
            return hit.image
        }

        // Try the requested size first. If the NAS is still generating it
        // (the fetch throws on the HTTP-404 / error-page it returns while
        // `converting`) OR the bytes fail to decode (e.g. a stale error page
        // cached on disk from before that was fixed), fall back to `preview`,
        // which Synology generates first and is usually `ready` when the
        // smaller sizes are not. Cache the result under the REQUESTED size's
        // key so the fallback is transparent to the caller.
        var decoded = await fetchAndDecode(space: space, asset: asset, size: size)
        if decoded == nil, size != .preview {
            decoded = await fetchAndDecode(space: space, asset: asset, size: .preview)
        }

        if let image = decoded {
            memory.setObject(CacheBox(image), forKey: nsKey(key), cost: Self.byteCost(image))
        }
        return decoded
    }

    /// Fetches one size from the core and decodes it, returning `nil` if either
    /// step fails (a not-yet-generated size throws; an error page fails to
    /// decode). No caching here: the caller owns the memory tier and keys it on
    /// the originally requested size.
    private func fetchAndDecode(space: Space, asset: Asset, size: ThumbnailSize) async -> CGImage? {
        let data: ThumbnailData
        do {
            // Must pass asset.unitId, not asset.id: the NAS thumbnail endpoint
            // keys on unit_id (additional.thumbnail.unit_id from the browse
            // response); sending the browse item id returns an html error page.
            data = try await client.thumbnail(
                space: space, unitId: asset.unitId, cacheKey: asset.cacheKey, size: size)
        } catch {
            return nil
        }
        let maxPixel = Self.maxPixel(for: size)
        let path = data.cachedPath
        return await Task.detached(priority: .utility) {
            ImageDownsample.downsample(fileURL: URL(fileURLWithPath: path), maxPixel: maxPixel)
        }.value
    }

    /// Drops cached entries for `assetId` so the next lookup re-fetches from
    /// the core. `NSCache` has no key-prefix removal API, and thumbnails are
    /// small relative to the byte budget, so this clears the whole in-memory
    /// tier rather than tracking every `ThumbKey` ever inserted for the
    /// asset (all size variants, potentially across a stale and a fresh
    /// `cacheKey`). The disk tier is unaffected: it is owned and invalidated
    /// by the core itself when `cacheKey` changes.
    func invalidate(assetId: Int64) {
        memory.removeAllObjects()
        _ = assetId
    }
}
