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
