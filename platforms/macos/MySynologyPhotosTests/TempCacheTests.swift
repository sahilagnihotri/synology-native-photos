import Testing
import Foundation
import PhotosCore
@testable import MySynologyPhotos

struct TempCacheTests {
    private func makeTempFile() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orig-\(UUID()).bin")
        FileManager.default.createFile(atPath: url.path, contents: Data([0, 1, 2]))
        return url.path
    }

    @Test func storeReturnsExistingPath() async {
        let cache = TempFileCache(limit: 4)
        let path = makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let url = await cache.store(path: path)
        #expect(url.path == path)
    }

    @Test func evictsOldestBeyondLimit() async {
        let cache = TempFileCache(limit: 2)
        var paths: [String] = []
        for _ in 0..<3 { let p = makeTempFile(); paths.append(p); _ = await cache.store(path: p) }
        #expect(FileManager.default.fileExists(atPath: paths[0]) == false)
        #expect(FileManager.default.fileExists(atPath: paths[2]) == true)
        for p in paths { try? FileManager.default.removeItem(atPath: p) }
    }

    @Test func clearAllRemovesResident() async {
        let cache = TempFileCache(limit: 4)
        let p = makeTempFile()
        _ = await cache.store(path: p)
        await cache.clearAll()
        #expect(FileManager.default.fileExists(atPath: p) == false)
    }

    // MARK: - store(path:preferredFilename:), extensioned copy for QuickLook

    @Test func storeWithPreferredFilenameCopiesToExtensionedPath() async {
        let cache = TempFileCache(limit: 4)
        let src = makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: src) }

        let url = await cache.store(path: src, preferredFilename: "IMG_0001.HEIC")

        #expect(url.pathExtension.lowercased() == "heic")
        #expect(url.path != src)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Original download-temp file is untouched by the copy.
        #expect(FileManager.default.fileExists(atPath: src))
        await cache.clearAll()
    }

    @Test func storeWithPreferredFilenameContentMatchesSource() async {
        let cache = TempFileCache(limit: 4)
        let src = makeTempFile()
        defer { try? FileManager.default.removeItem(atPath: src) }

        let url = await cache.store(path: src, preferredFilename: "clip.mov")
        let copied = try? Data(contentsOf: url)

        #expect(copied == Data([0, 1, 2]))
        await cache.clearAll()
    }

    @Test func evictionOfExtensionedEntriesRemovesTheCopyNotTheSource() async {
        let cache = TempFileCache(limit: 1)
        let srcA = makeTempFile()
        let srcB = makeTempFile()
        defer {
            try? FileManager.default.removeItem(atPath: srcA)
            try? FileManager.default.removeItem(atPath: srcB)
        }

        let urlA = await cache.store(path: srcA, preferredFilename: "a.jpg")
        let urlB = await cache.store(path: srcB, preferredFilename: "b.jpg")

        // The first copy was evicted once the cache exceeded its limit of 1.
        #expect(FileManager.default.fileExists(atPath: urlA.path) == false)
        #expect(FileManager.default.fileExists(atPath: urlB.path) == true)
        // Eviction only ever removes the cache's own copy, never the
        // original download-temp source file it was copied from.
        #expect(FileManager.default.fileExists(atPath: srcA) == true)
        await cache.clearAll()
    }

    // MARK: - Extension derivation from Asset filename / MediaKind

    @Test func extensionPrefersAssetFilenameSuffix() {
        let asset = Asset(
            id: 1, unitId: 10001, cacheKey: "ck", filename: "IMG_0001.HEIC", mediaKind: .photo,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        #expect(QuickLookFilename.derive(for: asset) == "IMG_0001.HEIC")
    }

    @Test func extensionFallsBackToPhotoWhenFilenameHasNoExtension() {
        let asset = Asset(
            id: 2, unitId: 10002, cacheKey: "ck", filename: "IMG_0002", mediaKind: .photo,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        #expect(QuickLookFilename.derive(for: asset) == "IMG_0002.jpg")
    }

    @Test func extensionFallsBackToVideoWhenFilenameHasNoExtension() {
        let asset = Asset(
            id: 3, unitId: 10003, cacheKey: "ck", filename: "clip", mediaKind: .video,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        #expect(QuickLookFilename.derive(for: asset) == "clip.mov")
    }

    @Test func extensionFallsBackToBinWhenUnknownAndNoExtension() {
        let asset = Asset(
            id: 4, unitId: 10004, cacheKey: "ck", filename: "mystery", mediaKind: .unknown,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        #expect(QuickLookFilename.derive(for: asset) == "mystery.bin")
    }

    @Test func extensionDerivationHandlesRawAndVideoContainersFromFilename() {
        let raw = Asset(
            id: 5, unitId: 10005, cacheKey: "ck", filename: "DSC_0005.NEF", mediaKind: .photo,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        let mp4 = Asset(
            id: 6, unitId: 10006, cacheKey: "ck", filename: "movie.mp4", mediaKind: .video,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        #expect(QuickLookFilename.derive(for: raw) == "DSC_0005.NEF")
        #expect(QuickLookFilename.derive(for: mp4) == "movie.mp4")
    }

    @Test func extensionDerivationSanitizesPathTraversalInFilename() {
        // A hostile/unexpected filename from the NAS must never be able to
        // place the QuickLook copy outside the temp cache directory.
        let asset = Asset(
            id: 7, unitId: 10007, cacheKey: "ck", filename: "../../etc/passwd.jpg", mediaKind: .photo,
            takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
            space: .personal, serverVersion: nil)
        let derived = QuickLookFilename.derive(for: asset)
        #expect(!derived.contains("/"))
        #expect(!derived.contains(".."))
        #expect(derived.hasSuffix(".jpg"))
    }
}
