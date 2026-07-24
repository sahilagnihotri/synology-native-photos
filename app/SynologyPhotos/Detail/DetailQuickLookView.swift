import SwiftUI
import AppKit
import Quartz
import PhotosCore

// Format support (read-only Phase 1):
//  - QLPreviewView renders HEIC, most camera RAW, and common video containers
//    from the downloaded original, provided the file on disk carries the
//    right extension (QuickLook's provider dispatch is extension/UTI driven,
//    not content-sniffed). `PhotosCoreClient.downloadOriginal` (Task 40 ->
//    37) writes the original to an extensionless core-owned temp path
//    (`syno-orig-<hash>`), so this view copies that file once into a
//    correctly-named entry inside `TempFileCache` before handing a URL to
//    QuickLook. Verify against real NAS originals in Task 53 (RealNAS) --
//    in particular whether any RAW container the NAS actually stores needs
//    a specific extension QuickLook doesn't ship a provider for out of the
//    box (e.g. some RAW variants render as a generic icon rather than a
//    real preview on stock macOS without a vendor plug-in installed).
//  - Live Photos re-pairing (still + paired MOV into one PHLivePhoto) is
//    DEFERRED past Phase 1. The MVP previews the still and any paired video
//    as two separate originals, each opened on its own; no attempt is made
//    here to detect or rejoin a Live Photo pair.

/// Derives the filename QuickLook should see for an asset's downloaded
/// original, so the temp copy handed to `QLPreviewView` carries the
/// extension QuickLook's provider dispatch relies on.
enum QuickLookFilename {
    /// Extension used when an asset's `mediaKind` is photo-like but its own
    /// filename carries no extension at all (unexpected, but the NAS is an
    /// external system whose data this app must not trust blindly).
    private static let photoFallbackExtension = "jpg"
    /// Same fallback for `.video`.
    private static let videoFallbackExtension = "mov"
    /// Same fallback for `.unknown` (neither photo nor video reported).
    private static let unknownFallbackExtension = "bin"

    /// Returns a filesystem-safe filename for `asset`, suitable as the
    /// single path component of a file inside the temp cache directory.
    ///
    /// Preference order:
    /// 1. `asset.filename`'s own extension, when it has one, this is the
    ///    real filename as stored on the NAS, and by far the most reliable
    ///    signal for format-specific previewing (HEIC vs JPEG vs a specific
    ///    RAW variant vs MOV vs MP4 all matter to QuickLook's provider
    ///    dispatch, and only the original filename actually distinguishes
    ///    them).
    /// 2. A `mediaKind`-based fallback extension, when the filename has
    ///    none, so QuickLook still gets *a* usable extension rather than
    ///    none.
    ///
    /// The result is defensively sanitized: it is always a single path
    /// component (no `/`, no `..`), so a hostile or malformed filename
    /// reported by the NAS can never be used to escape the temp cache
    /// directory when this string is later appended as a path component.
    static func derive(for asset: Asset) -> String {
        let rawName = (asset.filename as NSString).lastPathComponent
        let ext = (rawName as NSString).pathExtension
        let base = sanitizeBaseName((rawName as NSString).deletingPathExtension)

        if !ext.isEmpty {
            return "\(base).\(sanitizeExtension(ext))"
        }

        switch asset.mediaKind {
        case .photo: return "\(base).\(photoFallbackExtension)"
        case .video: return "\(base).\(videoFallbackExtension)"
        case .unknown: return "\(base).\(unknownFallbackExtension)"
        }
    }

    /// Strips path separators and `..` segments from a candidate base name,
    /// falling back to a fixed placeholder if nothing usable remains (e.g.
    /// the whole filename was separators). Guarantees a non-empty result
    /// containing no `/`.
    private static func sanitizeBaseName(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "asset" : trimmed
    }

    private static func sanitizeExtension(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "/", with: "")
        return cleaned.isEmpty ? unknownFallbackExtension : cleaned
    }
}

/// Bounds downloaded originals in the temp dir by count; deletes the oldest
/// first.
///
/// Two ways to add an entry:
/// - `store(path:)`, tracks an already-correctly-placed file as-is and
///   returns its own URL unchanged. This is the shape Task 52's
///   `SignOutController` and this file's own required TDD tests depend on:
///   the cache can simply take ownership of a path it did not create.
/// - `store(path:preferredFilename:)`, copies the file at `path` (the
///   core's extensionless download-temp file) into a new file inside this
///   cache's own directory, named by `preferredFilename`, and tracks *that
///   copy* for eviction. The source file at `path` is never touched or
///   removed by this method or by later eviction of the copy, only this
///   cache's own copies are ever deleted. This is what
///   `DetailQuickLookView` uses, since `QLPreviewView` needs a
///   correctly-extensioned filename and the core's own temp path has none.
///
/// Both entry points share one eviction list and one count limit, so the
/// total number of files this cache is responsible for deleting never
/// exceeds `limit` regardless of which method added them.
actor TempFileCache {
    private let limit: Int
    private var order: [String] = []
    private lazy var cacheDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SynologyPhotosQuickLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init(limit: Int = 24) { self.limit = max(1, limit) }

    @discardableResult
    func store(path: String) -> URL {
        if !order.contains(path) { order.append(path) }
        evictIfNeeded()
        return URL(fileURLWithPath: path)
    }

    /// Copies `path` into this cache's directory under `preferredFilename`
    /// (de-duplicated with a short suffix if that name is already resident)
    /// and tracks the copy for count-bounded eviction. Returns the copy's
    /// URL. If the copy cannot be made (disk full, source vanished, etc.),
    /// falls back to tracking and returning the original `path` unchanged
    /// so a preview attempt is still possible, just without a guaranteed
    /// extension.
    @discardableResult
    func store(path: String, preferredFilename: String) -> URL {
        let destination = uniqueDestination(for: preferredFilename)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(atPath: path, toPath: destination.path)
        } catch {
            return store(path: path)
        }
        return store(path: destination.path)
    }

    private func uniqueDestination(for preferredFilename: String) -> URL {
        var candidate = cacheDir.appendingPathComponent(preferredFilename)
        if !order.contains(candidate.path) { return candidate }
        let ext = (preferredFilename as NSString).pathExtension
        let base = (preferredFilename as NSString).deletingPathExtension
        var attempt = 1
        repeat {
            let name = ext.isEmpty ? "\(base)-\(attempt)" : "\(base)-\(attempt).\(ext)"
            candidate = cacheDir.appendingPathComponent(name)
            attempt += 1
        } while order.contains(candidate.path)
        return candidate
    }

    func evictIfNeeded() {
        while order.count > limit {
            let victim = order.removeFirst()
            try? FileManager.default.removeItem(atPath: victim)
        }
    }

    func clearAll() {
        for p in order { try? FileManager.default.removeItem(atPath: p) }
        order.removeAll()
    }
}

/// Full-size photo/video detail view: downloads the original for `asset`
/// (via `PhotosCoreClient.downloadOriginal`, Task 40 -> 37) into a
/// count-bounded temp cache, then previews it with QuickLook.
///
/// Read-only: this view only ever downloads and previews. It never uploads,
/// edits, or deletes anything on the NAS, selecting a grid item and
/// opening detail cannot mutate NAS state.
struct DetailQuickLookView: NSViewRepresentable {
    let asset: Asset
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        preview.setAccessibilityIdentifier("detail.quicklook")
        return preview
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        let a = asset, s = space, c = client, tc = cache
        Task {
            do {
                let downloadedPath = try await c.downloadOriginal(
                    space: s, assetId: a.id, cacheKey: a.cacheKey)
                let filename = QuickLookFilename.derive(for: a)
                let url = await tc.store(path: downloadedPath, preferredFilename: filename)
                await MainActor.run { nsView.previewItem = url as NSURL }
            } catch {
                // Read-only: on failure, leave the preview empty; no
                // mutation of the NAS is ever attempted on this path.
            }
        }
    }
}
