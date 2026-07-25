import Testing
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotosCore
@testable import SynologyPhotos

/// Counts how many times the injected "download" closure ran, so a test can
/// assert the network was (or was not) hit. A reference type shared with the
/// closure; only ever mutated on the cache actor's executor while the test
/// awaits, then read after, so there is no concurrent access.
private final class CallCounter: @unchecked Sendable {
    var count = 0
}

struct OriginalImageCacheTests {
    // MARK: - Helpers

    private func freshCacheDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("orig-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a solid-color PNG of the given pixel size and returns its path.
    private func writePNG(width: Int, height: Int) -> String {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID()).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return url.path
    }

    /// Writes a raw file of exactly `bytes` bytes and returns its path.
    private func writeBytes(_ bytes: Int) -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID()).bin")
        try? Data(count: bytes).write(to: url)
        return url.path
    }

    // MARK: - Disk store / get by cacheKey

    @Test func ingestStoresAndGetsByCacheKey() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 1_000_000, diskLimitBytes: 10_000_000)

        let src = writeBytes(1234)
        defer { try? FileManager.default.removeItem(atPath: src) }
        let stored = try await cache.ingest(cacheKey: "ck-1", preferredFilename: "IMG.jpg", sourcePath: src)

        #expect(FileManager.default.fileExists(atPath: stored.path))
        // Source file is untouched by the copy.
        #expect(FileManager.default.fileExists(atPath: src))
        let hit = await cache.cachedFileURL(cacheKey: "ck-1", preferredFilename: "IMG.jpg")
        #expect(hit?.path == stored.path)
        // A different cacheKey does not resolve to this file.
        let miss = await cache.cachedFileURL(cacheKey: "ck-other", preferredFilename: "IMG.jpg")
        #expect(miss == nil)
    }

    @Test func cachedFileURLMissesBeforeAnyIngest() async {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 1_000, diskLimitBytes: 1_000_000)
        let hit = await cache.cachedFileURL(cacheKey: "nope", preferredFilename: "x.jpg")
        #expect(hit == nil)
    }

    // MARK: - Size-based eviction

    @Test func sizeBasedEvictionRemovesOldestFirst() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Budget fits one 1000-byte file but not two.
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 1_000, diskLimitBytes: 1_500)

        let a = writeBytes(1000)
        let b = writeBytes(1000)
        defer { try? FileManager.default.removeItem(atPath: a); try? FileManager.default.removeItem(atPath: b) }

        _ = try await cache.ingest(cacheKey: "ck-a", preferredFilename: "a.jpg", sourcePath: a)
        _ = try await cache.ingest(cacheKey: "ck-b", preferredFilename: "b.jpg", sourcePath: b)

        // The older entry was evicted to stay under the byte budget.
        let hitA = await cache.cachedFileURL(cacheKey: "ck-a", preferredFilename: "a.jpg")
        let hitB = await cache.cachedFileURL(cacheKey: "ck-b", preferredFilename: "b.jpg")
        #expect(hitA == nil)
        #expect(hitB != nil)
        let usage = await cache.currentDiskUsage()
        #expect(usage == 1000)
        let count = await cache.diskFileCount()
        #expect(count == 1)
    }

    // MARK: - Downsampled decode

    @Test func displayImageDecodesDownsampledSmallerThanOriginal() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 100_000_000, diskLimitBytes: 100_000_000)

        let bigPath = writePNG(width: 2000, height: 1500)
        defer { try? FileManager.default.removeItem(atPath: bigPath) }

        let image = try await cache.displayImage(
            cacheKey: "ck-big", maxPixel: 240, preferredFilename: "big.png",
            download: { bigPath })
        let img = try #require(image)
        // The decoded image is downsampled to the requested max pixel, far
        // smaller than the 2000x1500 original.
        #expect(max(img.size.width, img.size.height) <= 240)
        #expect(max(img.size.width, img.size.height) < 2000)
    }

    // MARK: - Second open served from cache (no re-download)

    @Test func secondDisplayServedFromRamWithoutDownloading() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 100_000_000, diskLimitBytes: 100_000_000)

        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = CallCounter()

        let first = try await cache.displayImage(
            cacheKey: "ck-r", maxPixel: 256, preferredFilename: "r.png",
            download: { counter.count += 1; return path })
        #expect(first != nil)
        #expect(counter.count == 1)

        // Remove the on-disk copy so the second open can ONLY be served from
        // the RAM tier: it must still return an image and must not download.
        let name = OriginalDiskName.name(cacheKey: "ck-r", preferredFilename: "r.png")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))

        let second = try await cache.displayImage(
            cacheKey: "ck-r", maxPixel: 256, preferredFilename: "r.png",
            download: { counter.count += 1; return path })
        #expect(second != nil)
        #expect(counter.count == 1)
    }

    @Test func diskHitAcrossInstancesServesWithoutDownloading() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = CallCounter()

        // First instance downloads once and writes the original to disk.
        let first = OriginalImageCache(cacheDir: dir, ramLimitBytes: 100_000_000, diskLimitBytes: 100_000_000)
        _ = try await first.displayImage(
            cacheKey: "ck-d", maxPixel: 256, preferredFilename: "d.png",
            download: { counter.count += 1; return path })
        #expect(counter.count == 1)

        // A fresh instance over the same directory (RAM empty, simulating a
        // relaunch) serves the same asset straight off disk, no download.
        let second = OriginalImageCache(cacheDir: dir, ramLimitBytes: 100_000_000, diskLimitBytes: 100_000_000)
        let image = try await second.displayImage(
            cacheKey: "ck-d", maxPixel: 256, preferredFilename: "d.png",
            download: { counter.count += 1; return path })
        #expect(image != nil)
        #expect(counter.count == 1)
    }

    // MARK: - RAM cost bounding

    @Test func ramLimitIsConfigurableAndStillAdmits() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A tiny RAM budget (smaller than a single decoded image) still admits
        // the decode; the cost limit governs eviction, not admission, mirroring
        // ThumbnailCache's own byte-budget behavior.
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 1024, diskLimitBytes: 100_000_000)
        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let image = try await cache.displayImage(
            cacheKey: "ck-tiny", maxPixel: 256, preferredFilename: "t.png",
            download: { path })
        #expect(image != nil)
    }

    // MARK: - Clear

    @Test func clearDropsDiskAndForcesReDownload() async throws {
        let dir = freshCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = OriginalImageCache(cacheDir: dir, ramLimitBytes: 100_000_000, diskLimitBytes: 100_000_000)

        let path = writePNG(width: 800, height: 600)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let counter = CallCounter()

        _ = try await cache.displayImage(
            cacheKey: "ck-c", maxPixel: 256, preferredFilename: "c.png",
            download: { counter.count += 1; return path })
        #expect(counter.count == 1)
        #expect(await cache.currentDiskUsage() > 0)

        await cache.clear()
        #expect(await cache.currentDiskUsage() == 0)
        #expect(await cache.diskFileCount() == 0)

        // After a clear, both tiers miss, so the next open downloads again.
        _ = try await cache.displayImage(
            cacheKey: "ck-c", maxPixel: 256, preferredFilename: "c.png",
            download: { counter.count += 1; return path })
        #expect(counter.count == 2)
    }

    // MARK: - Disk name hardening

    @Test func diskNameIsASingleSafeComponentEvenForHostileInput() {
        let name = OriginalDiskName.name(
            cacheKey: "../../etc/passwd", preferredFilename: "../../evil.j/pg")
        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
        // Deterministic across calls (so a later launch resolves the same file).
        let again = OriginalDiskName.name(cacheKey: "../../etc/passwd", preferredFilename: "../../evil.j/pg")
        #expect(name == again)
    }
}
