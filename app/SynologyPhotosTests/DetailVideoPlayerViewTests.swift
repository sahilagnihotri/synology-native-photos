import Testing
import Foundation
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
