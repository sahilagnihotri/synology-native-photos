import Foundation
import AppKit
import CoreGraphics
import PhotosCore

/// Derives the on-disk filename for a cached original, keyed by the asset's
/// `cacheKey` (stable per original, changes only when the bytes change).
///
/// The name is `<hash>.<ext>`: a deterministic FNV-1a hash of the `cacheKey`
/// (hex digits only, so it survives across launches unlike Swift's per-process
/// randomized `hashValue`) plus a sanitized extension taken from the asset's
/// own filename. Because the base is pure hex and the extension is stripped of
/// any path separator, a hostile or malformed `cacheKey`/filename reported by
/// the NAS can never produce anything but a single, safe path component: it can
/// never escape the cache directory. This is the same hardening discipline
/// `QuickLookFilename`/`TempFileCache` apply, expressed for a cache keyed by
/// `cacheKey` rather than by the raw filename.
enum OriginalDiskName {
    private static let fallbackExtension = "bin"

    /// Deterministic 64-bit FNV-1a hash of `s`, hex-encoded. Deterministic
    /// across process launches (Swift's `Hasher`/`hashValue` is seeded per
    /// process and must NOT be used for a name that has to match a file
    /// written by an earlier launch).
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// A single, filesystem-safe path component `<hash(cacheKey)>.<ext>`.
    /// `preferredFilename` is only mined for its extension (the real name as
    /// stored on the NAS is the most reliable signal of format, and the
    /// extension is what ImageIO/AVFoundation dispatch a decoder from); the
    /// base is never taken from it, so nothing NAS-supplied reaches the name
    /// except a sanitized extension.
    static func name(cacheKey: String, preferredFilename: String) -> String {
        let rawExt = (preferredFilename as NSString).pathExtension
        let ext = sanitizeExtension(rawExt)
        return "\(stableHash(cacheKey)).\(ext)"
    }

    private static func sanitizeExtension(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? fallbackExtension : cleaned
    }
}

/// Two-tier cache for full originals feeding the detail viewer, the exact
/// mirror of `ThumbnailCache` one level up: instead of small grid thumbnails
/// it caches the full downloaded original (photo bytes or video file) plus a
/// downsampled decode of it, so opening a photo a second time never touches
/// the network and never re-decodes a huge image.
///
/// Tier 1 (RAM): an `NSCache` of decoded `NSImage`, bounded by total decoded
/// byte cost (not item count), so paging through a large library cannot blow
/// memory. Keyed by `cacheKey` plus the downsample target, since the same
/// original is decoded to different sizes for fit-display vs a zoomed full
/// decode.
///
/// Tier 2 (DISK): the raw downloaded original bytes, written atomically into a
/// dedicated cache directory under an `OriginalDiskName` and bounded by total
/// bytes with oldest-first (LRU) eviction. Survives relaunch: a photo opened
/// last session decodes straight off disk this session with no download. The
/// disk tier also backs video playback, which hands the cached file straight
/// to `AVPlayer` rather than re-downloading the whole movie every open.
///
/// Concurrency: an `actor`, so every mutation of the bookkeeping is serialized;
/// the network download and the pixel decode both happen off the actor (an
/// `async` download closure whose `await` releases the actor, and a
/// `Task.detached` decode) so a slow download or a large decode never blocks a
/// lookup for a different asset.
actor OriginalImageCache {
    /// Downsample target for a zoomed "full resolution" decode. A generous cap
    /// (8K) rather than truly unbounded: it is crisp well past 100% for this
    /// library's photos while still bounding the decoded bitmap so a single
    /// pathological original cannot exhaust memory.
    static let fullResolutionMaxPixel = 8192

    private let cacheDir: URL
    private let fileManager = FileManager.default

    private let ram = NSCache<NSString, ImageBox>()

    /// Total disk byte budget; eviction keeps resident bytes at or below this.
    private var diskLimitBytes: Int

    /// LRU order of resident disk filenames, oldest first. Populated lazily by
    /// `ensureScanned()` on first use from whatever a previous launch left
    /// behind, then maintained in memory as files are added/touched/evicted.
    private var diskOrder: [String] = []
    private var diskSizes: [String: Int] = [:]
    private var diskTotal = 0
    private var didScan = false

    /// Boxes a decoded `NSImage` for `NSCache` (which requires class values)
    /// alongside the decoded-byte cost used for eviction bookkeeping.
    final class ImageBox {
        let image: NSImage
        let cost: Int
        init(_ image: NSImage, cost: Int) {
            self.image = image
            self.cost = cost
        }
    }

    /// - Parameters:
    ///   - cacheDir: dedicated directory for the disk tier. Created if absent.
    ///     A subdirectory of the app's Caches folder in production, or a temp
    ///     dir in tests.
    ///   - ramLimitBytes: total decoded-byte budget for the RAM tier.
    ///   - diskLimitBytes: total byte budget for the disk tier.
    init(cacheDir: URL, ramLimitBytes: Int, diskLimitBytes: Int) {
        self.cacheDir = cacheDir
        self.diskLimitBytes = max(0, diskLimitBytes)
        ram.totalCostLimit = max(0, ramLimitBytes)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Photo decode (RAM + disk + network)

    /// Resolves a decoded, downsampled `NSImage` for the original identified by
    /// `cacheKey`, sized to `maxPixel` for fit-display.
    ///
    /// Order of operations, exactly the three tiers the detail load path wants:
    /// (a) a RAM hit for this `cacheKey`+`maxPixel` returns instantly; (b) a
    /// disk hit decodes the cached original downsampled off the actor, then
    /// populates RAM; (c) a full miss calls `download` ONCE, ingests the bytes
    /// into the disk tier keyed by `cacheKey`, then decodes + caches. The
    /// network is only ever touched on a disk miss. Returns `nil` if the file
    /// cannot be decoded as an image (a corrupt or non-image original), which
    /// the caller surfaces as a visible "could not open" state.
    func displayImage(
        cacheKey: String,
        maxPixel: Int,
        preferredFilename: String,
        download: () async throws -> String
    ) async throws -> NSImage? {
        let ramKey = ramKey(cacheKey: cacheKey, maxPixel: maxPixel)
        if let hit = ram.object(forKey: ramKey) { return hit.image }

        let url = try await ensureFileURL(
            cacheKey: cacheKey, preferredFilename: preferredFilename, download: download)
        guard let image = await Self.decode(url: url, maxPixel: maxPixel) else { return nil }
        ram.setObject(ImageBox(image.image, cost: image.cost), forKey: ramKey)
        return image.image
    }

    /// Resolves a near-full-resolution decode for the zoomed-in detail view,
    /// used only once the user magnifies past fit so the initial (downsampled)
    /// open stays fast. Serves the bytes from the disk tier when present
    /// (populated by the earlier `displayImage`), or downloads once on a disk
    /// miss. Cached in RAM under the full-resolution target so a second zoom of
    /// the same photo is instant.
    func fullImage(
        cacheKey: String,
        preferredFilename: String,
        download: () async throws -> String
    ) async throws -> NSImage? {
        try await displayImage(
            cacheKey: cacheKey,
            maxPixel: Self.fullResolutionMaxPixel,
            preferredFilename: preferredFilename,
            download: download)
    }

    // MARK: - Disk file (photos and videos share this)

    /// The cached original's file URL if the disk tier already holds it, else
    /// `nil`. Bumps LRU recency on a hit. Never touches the network. This is
    /// what the video player consults BEFORE calling `videoPlaybackSource`, so
    /// a re-open plays the cached movie instead of re-downloading it.
    func cachedFileURL(cacheKey: String, preferredFilename: String) -> URL? {
        ensureScanned()
        let name = OriginalDiskName.name(cacheKey: cacheKey, preferredFilename: preferredFilename)
        let url = cacheDir.appendingPathComponent(name)
        guard diskSizes[name] != nil || fileManager.fileExists(atPath: url.path) else { return nil }
        adopt(name: name, url: url)
        touch(name)
        return url
    }

    /// Copies the file at `sourcePath` into the disk tier under this
    /// `cacheKey`'s name (atomically: copy to a temp in the same directory,
    /// then rename), tracks it for byte-bounded eviction, and returns the
    /// cached copy's URL. The source file is never touched or removed. Used by
    /// the video path to cache a freshly downloaded movie by `cacheKey`.
    @discardableResult
    func ingest(cacheKey: String, preferredFilename: String, sourcePath: String) throws -> URL {
        ensureScanned()
        let name = OriginalDiskName.name(cacheKey: cacheKey, preferredFilename: preferredFilename)
        let url = cacheDir.appendingPathComponent(name)
        try writeIntoCache(sourcePath: sourcePath, name: name, destination: url)
        return url
    }

    /// The disk tier's file URL for `cacheKey`, downloading + ingesting once on
    /// a miss. Shared by the photo decode paths above; kept internal so a decode
    /// failure and a download failure stay distinct at the call site.
    private func ensureFileURL(
        cacheKey: String,
        preferredFilename: String,
        download: () async throws -> String
    ) async throws -> URL {
        if let url = cachedFileURL(cacheKey: cacheKey, preferredFilename: preferredFilename) {
            return url
        }
        let sourcePath = try await download()
        return try ingest(cacheKey: cacheKey, preferredFilename: preferredFilename, sourcePath: sourcePath)
    }

    // MARK: - Limits, usage, teardown

    /// Live-applies a new RAM byte budget (e.g. from the Settings panel).
    func setRamLimit(_ bytes: Int) {
        ram.totalCostLimit = max(0, bytes)
    }

    /// Live-applies a new disk byte budget and immediately evicts down to it.
    func setDiskLimit(_ bytes: Int) {
        diskLimitBytes = max(0, bytes)
        ensureScanned()
        evictIfNeeded()
    }

    /// Total bytes currently resident on disk (for the Settings usage line).
    func currentDiskUsage() -> Int {
        ensureScanned()
        return diskTotal
    }

    /// Number of cached originals currently on disk.
    func diskFileCount() -> Int {
        ensureScanned()
        return diskOrder.count
    }

    /// Drops every cached original from RAM and disk (sign-out, or the
    /// Settings "Clear cache" button). Leaves the cache directory in place so
    /// the next fetch does not have to recreate it.
    func clear() {
        ram.removeAllObjects()
        ensureScanned()
        for name in diskOrder {
            try? fileManager.removeItem(at: cacheDir.appendingPathComponent(name))
        }
        diskOrder.removeAll()
        diskSizes.removeAll()
        diskTotal = 0
    }

    // MARK: - Internals

    private func ramKey(cacheKey: String, maxPixel: Int) -> NSString {
        "\(cacheKey)|\(maxPixel)" as NSString
    }

    /// Decodes `url` downsampled to `maxPixel` off the actor and wraps it as an
    /// `NSImage` sized to the decoded pixel dimensions (so the detail view's
    /// aspect-fit is correct). Returns the image plus its decoded-byte cost.
    private static func decode(url: URL, maxPixel: Int) async -> (image: NSImage, cost: Int)? {
        let decoded: CGImage? = await Task.detached(priority: .userInitiated) {
            ImageDownsample.downsample(fileURL: url, maxPixel: maxPixel)
        }.value
        guard let cg = decoded else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return (image, cg.bytesPerRow * cg.height)
    }

    /// Atomically places the bytes at `sourcePath` at `destination` inside the
    /// cache dir: copy to a temp sibling, remove any stale entry, rename into
    /// place, then record its size and run eviction. Copying (not reading into
    /// memory) keeps a large original from doubling in RAM during ingest.
    private func writeIntoCache(sourcePath: String, name: String, destination: URL) throws {
        // The cache directory can be removed out from under this actor by
        // `SignOutController`'s wipe of the account cache dir; recreate it
        // (idempotent) so the first ingest after a re-login does not fail.
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let temp = cacheDir.appendingPathComponent(".ingest-\(UUID().uuidString)")
        try? fileManager.removeItem(at: temp)
        try fileManager.copyItem(atPath: sourcePath, toPath: temp.path)
        if let existing = diskSizes[name] { diskTotal -= existing; diskSizes[name] = nil; diskOrder.removeAll { $0 == name } }
        if fileManager.fileExists(atPath: destination.path) { try? fileManager.removeItem(at: destination) }
        do {
            try fileManager.moveItem(at: temp, to: destination)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw error
        }
        let size = Self.fileSize(fileManager, atPath: destination.path)
        diskSizes[name] = size
        diskTotal += size
        diskOrder.append(name)
        evictIfNeeded()
    }

    /// On-disk byte size of the file at `path`, or 0 if it cannot be read.
    private static func fileSize(_ fileManager: FileManager, atPath path: String) -> Int {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return 0 }
        return size
    }

    /// Moves `name` to the most-recently-used end of the LRU order.
    private func touch(_ name: String) {
        guard let idx = diskOrder.firstIndex(of: name) else {
            diskOrder.append(name)
            return
        }
        diskOrder.remove(at: idx)
        diskOrder.append(name)
    }

    /// Records a disk file discovered outside `writeIntoCache` (a hit on a file
    /// left by a previous launch that the scan may already know, or a race).
    private func adopt(name: String, url: URL) {
        guard diskSizes[name] == nil else { return }
        let size = Self.fileSize(fileManager, atPath: url.path)
        diskSizes[name] = size
        diskTotal += size
        if !diskOrder.contains(name) { diskOrder.append(name) }
    }

    /// Evicts oldest-first until resident bytes fit the disk budget, always
    /// keeping at least the most-recently-added entry so a single original
    /// larger than the whole budget is still served rather than deleted out
    /// from under the caller that just wrote it.
    private func evictIfNeeded() {
        while diskTotal > diskLimitBytes, diskOrder.count > 1 {
            let victim = diskOrder.removeFirst()
            if let size = diskSizes.removeValue(forKey: victim) { diskTotal -= size }
            try? fileManager.removeItem(at: cacheDir.appendingPathComponent(victim))
        }
    }

    /// One-time scan of the cache directory so a fresh actor instance inherits
    /// whatever a previous launch cached, ordered oldest-first by modification
    /// date to approximate LRU across launches. Temp ingest files are ignored.
    private func ensureScanned() {
        guard !didScan else { return }
        didScan = true
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let sized: [(name: String, size: Int, date: Date)] = entries.compactMap { url in
            let name = url.lastPathComponent
            if name.hasPrefix(".ingest-") { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let date = values?.contentModificationDate ?? .distantPast
            return (name, size, date)
        }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            diskOrder.append(entry.name)
            diskSizes[entry.name] = entry.size
            diskTotal += entry.size
        }
        evictIfNeeded()
    }
}
