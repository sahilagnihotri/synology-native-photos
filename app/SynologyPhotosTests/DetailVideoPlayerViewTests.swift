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
            download: { _, _ in URL(fileURLWithPath: "/dev/null") },
            makeImage: { _ in NSImage(size: NSSize(width: 1, height: 1)) })
        #expect(loader.state == .loading)
    }

    @Test func movesToLoadedOnAValidImage() async {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let loader = DetailImageLoader(
            download: { _, _ in URL(fileURLWithPath: "/tmp/whatever.jpg") },
            makeImage: { _ in image })
        await loader.load(asset: photo(), space: .personal)
        #expect(loader.state == .loaded(image))
    }

    @Test func movesToFailedWhenTheDownloadThrows() async {
        let loader = DetailImageLoader(
            download: { _, _ in throw DownloadFailed() },
            makeImage: { _ in NSImage(size: NSSize(width: 1, height: 1)) })
        await loader.load(asset: photo(), space: .personal)
        #expect(loader.state == .failed("Could not load this photo."))
    }

    @Test func movesToFailedWhenTheFileCannotBeDecoded() async {
        let loader = DetailImageLoader(
            download: { _, _ in URL(fileURLWithPath: "/tmp/not-an-image") },
            makeImage: { _ in nil })
        await loader.load(asset: photo(), space: .personal)
        #expect(loader.state == .failed("This file could not be opened as an image."))
    }
}
