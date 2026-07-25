import Testing
import Foundation
import AppKit
import PhotosCore
@testable import SynologyPhotos

/// Exercises `VideoPlaybackAssetBuilder.resolve`'s pure URL/header
/// decision, kept free of a live `AVPlayer`/`NSView`/`AVURLAsset` (whose
/// options are write-only, not readable back out) so the auth-handling
/// logic is verifiable without spinning up playback.
struct VideoPlaybackAssetBuilderTests {
    @Test func localFileResolvesToAPlainFileURLWithNoHeaders() {
        let source = VideoPlaybackSource.localFile(path: "/tmp/syno-orig-abc123")
        let resolved = VideoPlaybackAssetBuilder.resolve(source: source, synoToken: "irrelevant-for-local-file")
        #expect(resolved?.url == URL(fileURLWithPath: "/tmp/syno-orig-abc123"))
        #expect(resolved?.url.isFileURL == true)
        #expect(resolved?.options.isEmpty == true)
    }

    @Test func urlSourceAttachesSynoTokenAsHttpHeaderWhenPresent() {
        let source = VideoPlaybackSource.url(url: "https://nas.example.com:5001/webapi/entry.cgi?stream=1")
        let resolved = VideoPlaybackAssetBuilder.resolve(source: source, synoToken: "TOKEN123")
        let headers = resolved?.options[VideoPlaybackAssetBuilder.httpHeaderFieldsOptionKey] as? [String: String]
        #expect(headers?["X-SYNO-TOKEN"] == "TOKEN123")
    }

    @Test func urlSourceOmitsHeaderWhenNoTokenPresent() {
        let source = VideoPlaybackSource.url(url: "https://nas.example.com:5001/webapi/entry.cgi?stream=1")
        let resolved = VideoPlaybackAssetBuilder.resolve(source: source, synoToken: nil)
        #expect(resolved?.options.isEmpty == true)
    }

    @Test func malformedUrlSourceResolvesToNilRatherThanCrashing() {
        let source = VideoPlaybackSource.url(url: "")
        let resolved = VideoPlaybackAssetBuilder.resolve(source: source, synoToken: "TOKEN")
        #expect(resolved == nil)
    }

    @Test func makeAssetFallsBackToADevNullFileURLForAMalformedUrlSource() {
        let source = VideoPlaybackSource.url(url: "")
        let asset = VideoPlaybackAssetBuilder.makeAsset(source: source, synoToken: "TOKEN")
        #expect(asset.url.isFileURL)
    }
}

/// Exercises the video temp-filename derivation, the guarantee that a
/// `.localFile` playback source reaches AVFoundation with an extension it can
/// dispatch a container decoder from, and the failure-message mapping. These
/// are the pure/testable parts of the fix that stops an extensionless
/// download from playing as a silent black frame.
struct VideoPlaybackPreparationTests {
    private func videoAsset(filename: String, containerType: String = "") -> Asset {
        Asset(id: 1, unitId: 1, cacheKey: "k", filename: filename, mediaKind: .video,
              takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
              space: .personal, serverVersion: nil,
              rating: 0, description: "", camera: "", aperture: "", exposureTime: "",
              focalLength: "", iso: "", lens: "", duration: "", framerate: "",
              videoCodec: "", containerType: containerType)
    }

    // MARK: VideoTempFilename recognition

    @Test func recognizesCommonVideoExtensionsCaseInsensitively() {
        #expect(VideoTempFilename.isRecognizedVideoExtension("mov"))
        #expect(VideoTempFilename.isRecognizedVideoExtension("MOV"))
        #expect(VideoTempFilename.isRecognizedVideoExtension("mp4"))
        #expect(!VideoTempFilename.isRecognizedVideoExtension("heic"))
        #expect(!VideoTempFilename.isRecognizedVideoExtension(""))
    }

    @Test func detectsWhetherAPathAlreadyCarriesAVideoExtension() {
        // The core's download temp file is extensionless: needs a copy.
        #expect(!VideoTempFilename.pathHasRecognizedExtension("/tmp/syno-orig-abc123"))
        #expect(VideoTempFilename.pathHasRecognizedExtension("/tmp/clip.mov"))
    }

    // MARK: VideoTempFilename.derive

    @Test func deriveKeepsAVideoFilenamesOwnExtension() {
        #expect(VideoTempFilename.derive(for: videoAsset(filename: "IMG_1870.MOV")) == "IMG_1870.MOV")
    }

    @Test func deriveFallsBackToMovWhenTheFilenameHasNoExtension() {
        #expect(VideoTempFilename.derive(for: videoAsset(filename: "clip")) == "clip.mov")
    }

    @Test func deriveRepairsANonVideoFilenameExtensionUsingContainerType() {
        // A Live Photo whose asset filename is the still's .heic must not be
        // handed to AVURLAsset as ".heic"; the reported container wins.
        #expect(VideoTempFilename.derive(for: videoAsset(filename: "live.heic", containerType: "mp4")) == "live.mp4")
    }

    @Test func deriveFallsBackToMovWhenFilenameExtIsNonVideoAndNoContainerType() {
        #expect(VideoTempFilename.derive(for: videoAsset(filename: "live.heic")) == "live.mov")
    }

    // MARK: preparedSource

    @Test func preparedSourceReExtensionsAnExtensionlessLocalFile() async throws {
        // A real extensionless temp file, exactly the shape the core's
        // download returns; preparedSource must hand back a path AVFoundation
        // can recognize, with the bytes actually present.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("syno-orig-\(UUID().uuidString)")
        try Data([0x00, 0x01, 0x02]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cache = TempFileCache()
        let source = VideoPlaybackSource.localFile(path: tmp.path)
        let prepared = await DetailVideoPlayerView.preparedSource(
            from: source, asset: videoAsset(filename: "IMG_1870.MOV"), cache: cache)

        guard case .localFile(let preparedPath) = prepared else {
            Issue.record("expected a .localFile source back")
            return
        }
        #expect(VideoTempFilename.pathHasRecognizedExtension(preparedPath))
        #expect(FileManager.default.fileExists(atPath: preparedPath))
        await cache.clearAll()
    }

    @Test func preparedSourceLeavesAnAlreadyExtensionedLocalFileUnchanged() async {
        let cache = TempFileCache()
        let source = VideoPlaybackSource.localFile(path: "/tmp/already.mov")
        let prepared = await DetailVideoPlayerView.preparedSource(
            from: source, asset: videoAsset(filename: "already.mov"), cache: cache)
        #expect(prepared == source)
    }

    @Test func preparedSourcePassesAUrlSourceThrough() async {
        let cache = TempFileCache()
        let source = VideoPlaybackSource.url(url: "https://nas.example.com/stream")
        let prepared = await DetailVideoPlayerView.preparedSource(
            from: source, asset: videoAsset(filename: "IMG.MOV"), cache: cache)
        #expect(prepared == source)
    }

    // MARK: failure message

    @Test func messageUsesTheCoreErrorUserMessage() {
        let message = DetailVideoPlayerView.message(for: CoreError.Network(message: "unreachable"))
        #expect(message.contains("Network problem"))
    }

    @Test func messageFallsBackForANonCoreError() {
        struct SomeOtherError: Error {}
        #expect(DetailVideoPlayerView.message(for: SomeOtherError()) == "This video could not be played.")
    }
}

/// Exercises the cache-first video source resolver: a first open downloads
/// once and caches the movie by `cacheKey`; a re-open plays the cached file
/// without touching `videoPlaybackSource` (and thus without re-downloading).
struct VideoCacheResolverTests {
    private func videoAsset() -> Asset {
        Asset(id: 1, unitId: 1, cacheKey: "vk-1", filename: "IMG_1870.MOV", mediaKind: .video,
              takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
              space: .personal, serverVersion: nil)
    }

    private func freshCache() -> OriginalImageCache {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vid-cache-\(UUID().uuidString)", isDirectory: true)
        return OriginalImageCache(cacheDir: dir, ramLimitBytes: 1_000_000, diskLimitBytes: 100_000_000)
    }

    @Test func firstOpenDownloadsAndCachesSecondOpenServesFromDisk() async throws {
        // A real file standing in for the core's downloaded original.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)")
        try Data([0x00, 0x11, 0x22, 0x33]).write(to: src)
        defer { try? FileManager.default.removeItem(at: src) }

        let fake = FakePhotosCore()
        fake.videoPlaybackSourceResult = .success(.localFile(path: src.path))
        let client = PhotosCoreClient(core: fake)
        let originalCache = freshCache()
        let tempCache = TempFileCache()
        let asset = videoAsset()

        let first = try await DetailVideoPlayerView.resolvePlayableSource(
            asset: asset, space: .personal, client: client, originalCache: originalCache, cache: tempCache)
        guard case .localFile(let firstPath) = first else {
            Issue.record("expected a .localFile source"); return
        }
        // The played file is the cached copy (video-extensioned), not the raw
        // download temp, and it really exists.
        #expect(firstPath != src.path)
        #expect(VideoTempFilename.pathHasRecognizedExtension(firstPath))
        #expect(FileManager.default.fileExists(atPath: firstPath))
        #expect(fake.videoPlaybackSourceCallCount == 1)

        let second = try await DetailVideoPlayerView.resolvePlayableSource(
            asset: asset, space: .personal, client: client, originalCache: originalCache, cache: tempCache)
        guard case .localFile(let secondPath) = second else {
            Issue.record("expected a .localFile source"); return
        }
        // Re-open serves the same cached file and never re-downloads.
        #expect(secondPath == firstPath)
        #expect(fake.videoPlaybackSourceCallCount == 1)

        await originalCache.clear()
    }
}

/// Exercises the detail image renderer's state machine (the photo branch),
/// independent of a real NAS download or a real image on disk: both the
/// download and the decode step are injected closures, so loading -> loaded
/// and loading -> failed are verifiable directly.
@MainActor
struct DetailImageLoaderTests {
    private func photo() -> Asset {
        Asset(id: 1, unitId: 1, cacheKey: "k", filename: "IMG_1.jpg", mediaKind: .photo,
              takenAt: nil, addedAt: nil, width: nil, height: nil, fileSize: nil,
              space: .personal, serverVersion: nil)
    }

    private struct DownloadFailed: Error {}

    @Test func startsInLoadingBeforeAnyLoad() {
        let loader = DetailImageLoader(
            loadDisplay: { _, _ in NSImage(size: NSSize(width: 1, height: 1)) })
        #expect(loader.state == .loading)
    }

    @Test func movesToLoadedOnAValidImage() async {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let loader = DetailImageLoader(loadDisplay: { _, _ in image })
        await loader.load(asset: photo(), space: .personal)
        #expect(loader.state == .loaded(image))
    }

    @Test func movesToFailedWhenTheLoadThrows() async {
        let loader = DetailImageLoader(loadDisplay: { _, _ in throw DownloadFailed() })
        await loader.load(asset: photo(), space: .personal)
        #expect(loader.state == .failed("Could not load this photo."))
    }

    @Test func movesToFailedWhenTheFileCannotBeDecoded() async {
        let loader = DetailImageLoader(loadDisplay: { _, _ in nil })
        await loader.load(asset: photo(), space: .personal)
        #expect(loader.state == .failed("This file could not be opened as an image."))
    }

    @Test func showsCachedThumbnailAsPlaceholderWhileLoading() async {
        let thumbnail = NSImage(size: NSSize(width: 8, height: 6))
        let loader = DetailImageLoader(
            loadDisplay: { _, _ in NSImage(size: NSSize(width: 2, height: 2)) },
            placeholderFor: { _ in thumbnail })
        await loader.load(asset: photo(), space: .personal)
        // The placeholder is captured up front so the loading frame can show it.
        #expect(loader.placeholder === thumbnail)
    }

    @Test func loadFullResolutionPopulatesFromCacheOnlyOnce() async {
        let full = NSImage(size: NSSize(width: 9, height: 9))
        var fullCalls = 0
        let loader = DetailImageLoader(
            loadDisplay: { _, _ in NSImage(size: NSSize(width: 2, height: 2)) },
            loadFull: { _, _ in fullCalls += 1; return full })
        await loader.load(asset: photo(), space: .personal)
        await loader.loadFullResolutionIfNeeded(asset: photo(), space: .personal)
        await loader.loadFullResolutionIfNeeded(asset: photo(), space: .personal)
        #expect(loader.fullResolution === full)
        #expect(loader.displayImage === full)
        #expect(fullCalls == 1)
    }

    @Test func displayMaxPixelIsBoundedAndScaledToTheScreen() {
        // A retina 1440-point screen -> 2880 native px, within bounds.
        #expect(DetailImageLoader.displayMaxPixel(screenMaxDimension: 1440, scale: 2) == 2880)
        // Below the floor clamps up; a huge external display clamps down.
        #expect(DetailImageLoader.displayMaxPixel(screenMaxDimension: 320, scale: 1) == 1024)
        #expect(DetailImageLoader.displayMaxPixel(screenMaxDimension: 6016, scale: 2) == 4096)
        // No screen falls back to a sane default rather than crashing.
        #expect(DetailImageLoader.displayMaxPixel(screenMaxDimension: nil, scale: nil) == 3200)
    }
}
