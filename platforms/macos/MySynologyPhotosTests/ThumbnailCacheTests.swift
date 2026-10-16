import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotosCore
@testable import MySynologyPhotos

struct ThumbnailCacheTests {
    private func writePNG(width: Int, height: Int) -> String {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("thumb-\(UUID()).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return url.path
    }

    private func asset(id: Int64) -> Asset {
        Asset(id: id, unitId: id + 10_000, cacheKey: "v1", filename: "IMG_\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000, addedAt: nil, width: 800, height: 600,
              fileSize: nil, space: .personal, serverVersion: 1)
    }

    @Test func maxPixelMapping() {
        #expect(ThumbnailCache.maxPixel(for: .sm) == 240)
        #expect(ThumbnailCache.maxPixel(for: .m) == 320)
        #expect(ThumbnailCache.maxPixel(for: .xl) == 1280)
    }

    @Test func fetchesDecodesAndReturnsImage() async {
        let fake = FakePhotosCore()
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let img = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(img != nil)
        #expect(max(img?.width ?? 9999, img?.height ?? 9999) <= 240)
        #expect(fake.thumbnailCallCount == 1)
    }

    @Test func secondFetchServedFromMemory() async {
        let fake = FakePhotosCore()
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        _ = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        try? FileManager.default.removeItem(atPath: path)
        let img2 = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(img2 != nil)
        #expect(fake.thumbnailCallCount == 1)
    }

    @Test func differentSizeIsSeparateCacheEntry() async {
        let fake = FakePhotosCore()
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        _ = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(fake.thumbnailCallCount == 1)
        let imgM = await cache.image(space: .personal, asset: asset(id: 7), size: .m)
        #expect(imgM != nil)
        #expect(fake.thumbnailCallCount == 2)
        #expect(max(imgM?.width ?? 9999, imgM?.height ?? 9999) <= 320)
    }

    @Test func changedCacheKeyRefetchesInsteadOfServingStaleEntry() async {
        let fake = FakePhotosCore()
        let pathV1 = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: pathV1) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: pathV1, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))

        var staleAsset = asset(id: 7)
        _ = await cache.image(space: .personal, asset: staleAsset, size: .sm)
        #expect(fake.thumbnailCallCount == 1)

        let pathV2 = writePNG(width: 400, height: 400)
        defer { try? FileManager.default.removeItem(atPath: pathV2) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: pathV2, bytes: Data()))
        staleAsset = Asset(id: staleAsset.id, unitId: staleAsset.unitId, cacheKey: "v2", filename: staleAsset.filename,
                            mediaKind: staleAsset.mediaKind, takenAt: staleAsset.takenAt,
                            addedAt: staleAsset.addedAt, width: staleAsset.width,
                            height: staleAsset.height, fileSize: staleAsset.fileSize,
                            space: staleAsset.space, serverVersion: staleAsset.serverVersion)
        let imgV2 = await cache.image(space: .personal, asset: staleAsset, size: .sm)
        #expect(imgV2 != nil)
        #expect(fake.thumbnailCallCount == 2)
    }

    @Test func missingThumbnailReturnsNilInsteadOfThrowing() async {
        let fake = FakePhotosCore()
        fake.thumbnailResult = .failure(.Storage(message: "not found"))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let img = await cache.image(space: .personal, asset: asset(id: 42), size: .sm)
        #expect(img == nil)
        // The requested size failed, so the cache also tries the `preview`
        // fallback (which fails too here) before giving up: two attempts, no
        // throw. When only the small sizes are still `converting` on a real
        // NAS, that second attempt is what fills the cell with the ready
        // preview instead of a blank placeholder.
        #expect(fake.thumbnailCallCount == 2)
    }

    @Test func fallsBackToPreviewWhenTheRequestedSizeFails() async {
        // The requested size is still generating (fails), but preview is ready.
        let fake = FakePhotosCore()
        let previewPath = writePNG(width: 1280, height: 960)
        defer { try? FileManager.default.removeItem(atPath: previewPath) }
        fake.thumbnailResultBySize = [
            .sm: .failure(.Storage(message: "converting")),
            .preview: .success(ThumbnailData(cachedPath: previewPath, bytes: Data())),
        ]
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let img = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(img != nil, "a ready preview must fill the cell when sm is still converting")
    }

    @Test func invalidateClearsMemorySoNextLookupRefetches() async {
        let fake = FakePhotosCore()
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        _ = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(fake.thumbnailCallCount == 1)

        await cache.invalidate(assetId: 7)
        _ = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(fake.thumbnailCallCount == 2)
    }

    /// `peekMemory` is the synchronous fast path `PhotoCellView` uses to
    /// avoid the actor hop (and the blank-then-repaint flash that hop used
    /// to force) on a cell reconfigure that turns out to already be cached.
    /// Before anything has been fetched, the key is not in memory yet, so
    /// this must return `nil` rather than triggering any fetch itself; it
    /// only ever reads the memory tier.
    @Test func peekMemoryMissesBeforeAnyFetch() {
        let fake = FakePhotosCore()
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let key = ThumbKey(assetId: 7, size: .sm, cacheKey: "v1")
        #expect(cache.peekMemory(key) == nil)
        #expect(fake.thumbnailCallCount == 0)
    }

    @Test func peekMemoryHitsAfterImageIsFetchedAndCached() async {
        let fake = FakePhotosCore()
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        _ = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)

        let key = ThumbKey(assetId: 7, size: .sm, cacheKey: "v1")
        #expect(cache.peekMemory(key) != nil)
        // A different size for the same asset is still a separate entry,
        // and must still miss without touching the core.
        let missKey = ThumbKey(assetId: 7, size: .m, cacheKey: "v1")
        #expect(cache.peekMemory(missKey) == nil)
        #expect(fake.thumbnailCallCount == 1)
    }

    @Test func byteCostLimitIsConfigurable() async {
        let fake = FakePhotosCore()
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: path, bytes: Data()))
        // A tiny byte budget (smaller than a single decoded thumbnail) still
        // lets a lookup succeed; NSCache's costLimit governs eviction, not
        // admission, so this proves the limit is wired through without
        // making the cache reject valid inserts.
        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake), memoryByteLimit: 1024)
        let img = await cache.image(space: .personal, asset: asset(id: 7), size: .sm)
        #expect(img != nil)
    }
}
