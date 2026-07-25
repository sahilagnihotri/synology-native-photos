import SwiftUI
import AppKit
import AVKit
import PhotosCore

// Video playback (read-only Phase 1 follow-up):
//  - Confirmed against the real NAS: SYNO.Foto.Streaming IS advertised in
//    SYNO.API.Info (versions 1-2), but every plausible method name tried
//    (stream, get, open, download, video, play, list, stream_get, get_stream)
//    answered with Synology error 103 ("no such method"). No working
//    streaming call was found, and the library has no true video item
//    (media_kind == video) yet either, only Live Photo stills (type "live",
//    which decode as MediaKind.unknown and are plain JPEGs on disk, not a
//    video container).
//  - Per the brief's "correctness over cleverness" directive, playback goes
//    through `PhotosCoreClient.videoPlaybackSource`, which today always
//    downloads the original (reusing the exact same path
//    `DetailQuickLookView` already relies on for photos) and returns
//    `.localFile(path:)`. AVPlayer opens that local file directly, so no
//    NAS auth (sid / X-SYNO-TOKEN) ever needs to reach AVURLAsset: the
//    bytes are already on disk by the time playback starts. The `.url`
//    case is handled too (future streaming optimization) using
//    AVURLAssetHTTPHeaderFieldsKey to carry X-SYNO-TOKEN, matching the
//    brief's guidance for whichever path a future working Streaming method
//    would need; nothing produces that case yet, so it is unexercised
//    against a real NAS response.

/// Hosts an `AVPlayerView` with Apple's own standard playback controls
/// (play/pause, scrubber, volume). Read-only: never uploads or mutates
/// anything, only plays back a local file or (once a working Streaming
/// method is found) a remote URL.
final class VideoPlayerContainerView: NSView {
    let playerView: AVPlayerView = {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }
}

/// Resolves `asset`'s `VideoPlaybackSource` and builds the `AVPlayerItem`
/// to hand to `AVPlayer`. Kept free of AppKit/NSView so the URL-vs-header
/// decision is unit-testable without a live player.
enum VideoPlaybackAssetBuilder {
    /// The Objective-C string constant `AVURLAssetHTTPHeaderFieldsKey`,
    /// spelled out literally: the current macOS SDK's Swift overlay does
    /// not expose this particular constant to Swift ("cannot find
    /// 'AVURLAssetHTTPHeaderFieldsKey' in scope" at compile time, confirmed
    /// while building this feature), even though the symbol is present in
    /// AVFoundation's binary (confirmed via `AVFoundation.tbd`). The string
    /// value itself is stable, documented Apple API and is the standard
    /// workaround for an ObjC string constant a given SDK version hides
    /// from Swift.
    static let httpHeaderFieldsOptionKey = "AVURLAssetHTTPHeaderFieldsKey"

    /// Resolves the `(url, options)` pair `makeAsset` would construct an
    /// `AVURLAsset` from, split out as its own pure function purely so it
    /// is unit-testable: `AVURLAsset` exposes no public getter for the
    /// options it was constructed with (confirmed while building this
    /// feature: `.options` is not a member of `AVURLAsset` in the current
    /// SDK), so the URL/header decision has to be verified before it is
    /// ever handed to the SDK type. Returns `nil` for a malformed `.url`
    /// source rather than throwing, matching `makeAsset`'s fail-safe
    /// fallback behavior.
    static func resolve(source: VideoPlaybackSource, synoToken: String?) -> (url: URL, options: [String: Any])? {
        switch source {
        case .localFile(let path):
            return (URL(fileURLWithPath: path), [:])
        case .url(let urlString):
            guard let url = URL(string: urlString) else { return nil }
            var options: [String: Any] = [:]
            if let synoToken {
                options[httpHeaderFieldsOptionKey] = ["X-SYNO-TOKEN": synoToken]
            }
            return (url, options)
        }
    }

    /// Builds an `AVURLAsset` for `source`. For `.localFile`, a plain file
    /// URL with no extra headers (the bytes are already local, no auth
    /// needed to read them). For `.url`, the NAS auth token is attached as
    /// an HTTP header via `httpHeaderFieldsOptionKey` rather than a query
    /// parameter, since the confirmed pattern elsewhere in this app
    /// (thumbnail/download) sends `X-SYNO-TOKEN` as a header, not embedded
    /// in the URL; `sid` is still sent as a query parameter on `urlString`
    /// itself when present; this path is unexercised against a real NAS
    /// response since no working Streaming URL has been found yet.
    static func makeAsset(source: VideoPlaybackSource, synoToken: String?) -> AVURLAsset {
        guard let (url, options) = resolve(source: source, synoToken: synoToken) else {
            // Malformed URL from a future streaming response: fail safe
            // with an asset that simply won't resolve, rather than crashing
            // on a force-unwrap.
            return AVURLAsset(url: URL(fileURLWithPath: "/dev/null"))
        }
        return AVURLAsset(url: url, options: options)
    }
}

/// Full-size video detail view: resolves `asset`'s playback source via
/// `PhotosCoreClient.videoPlaybackSource` (download-then-play-local today,
/// see the file header), then plays it with `AVPlayerView`'s own standard
/// transport controls.
///
/// Read-only: never uploads, edits, or deletes anything on the NAS.
struct DetailVideoPlayerView: NSViewRepresentable {
    let asset: Asset
    let space: Space
    let client: PhotosCoreClient
    let synoToken: String?

    func makeNSView(context: Context) -> VideoPlayerContainerView {
        VideoPlayerContainerView()
    }

    func updateNSView(_ nsView: VideoPlayerContainerView, context: Context) {
        guard context.coordinator.lastAssetId != asset.id else { return }
        context.coordinator.lastAssetId = asset.id
        // Stop whatever the previous asset was playing before loading the
        // next one, matching Photos' own behavior of not letting a
        // previous video keep playing audio once you've paged away.
        nsView.playerView.player?.pause()
        nsView.playerView.player = nil

        let a = asset, s = space, c = client, token = synoToken
        Task {
            do {
                let source = try await c.videoPlaybackSource(space: s, asset: a)
                guard context.coordinator.lastAssetId == a.id else { return }
                let urlAsset = VideoPlaybackAssetBuilder.makeAsset(source: source, synoToken: token)
                let item = AVPlayerItem(asset: urlAsset)
                let player = AVPlayer(playerItem: item)
                await MainActor.run {
                    guard context.coordinator.lastAssetId == a.id else { return }
                    nsView.playerView.player = player
                    player.play()
                }
            } catch {
                // Read-only: on failure, leave the player empty; no
                // mutation of the NAS is ever attempted on this path.
            }
        }
    }

    static func dismantleNSView(_ nsView: VideoPlayerContainerView, coordinator: Coordinator) {
        nsView.playerView.player?.pause()
        nsView.playerView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks which asset the hosted player is currently showing, the same
    /// pattern `DetailQuickLookView.Coordinator` uses, so a redundant
    /// SwiftUI re-render (paging did not actually change) does not restart
    /// playback or re-download the file.
    final class Coordinator {
        var lastAssetId: Int64?
    }
}
