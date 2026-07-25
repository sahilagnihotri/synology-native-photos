import SwiftUI
import AppKit
import AVKit
import PhotosCore

// Video playback (read-only Phase 1 follow-up):
//  - Confirmed against the real NAS: SYNO.Foto.Streaming IS advertised in
//    SYNO.API.Info (versions 1-2), but every plausible method name tried
//    (stream, get, open, download, video, play, list, stream_get, get_stream)
//    answered with Synology error 103 ("no such method"). No working
//    streaming call was found. Playback therefore goes through
//    `PhotosCoreClient.videoPlaybackSource`, which today downloads the
//    original (reusing the exact same path `DetailQuickLookView` relies on
//    for photos) and returns `.localFile(path:)`.
//  - The core's download temp file has NO extension. AVURLAsset/AVPlayer
//    dispatches a container decoder off the URL's path extension, and an
//    extensionless path is exactly what makes a real MOV come up as a silent
//    black frame. So a `.localFile` source is first copied into the temp
//    cache under a video-extensioned name (`VideoTempFilename.derive`) before
//    it reaches AVURLAsset, mirroring how the photo path re-extensions its
//    download. AVPlayer opens that local file directly, so no NAS auth
//    (sid / X-SYNO-TOKEN) ever needs to reach AVURLAsset.
//  - Every failure surfaces a visible error state, never a silent black
//    frame: a thrown download/resolve error shows the error overlay directly,
//    and an `AVPlayerItem` that transitions to `.failed` (an undecodable or
//    unreachable file) is observed via KVO and shown too.
//  - The `.url` case is handled (future streaming optimization) using
//    AVURLAssetHTTPHeaderFieldsKey to carry X-SYNO-TOKEN, matching the
//    thumbnail/download header pattern; nothing produces that case yet, so it
//    is unexercised against a real NAS response.

/// Filesystem-safe filename derivation for a video asset's downloaded
/// original, so the local copy handed to `AVURLAsset` carries an extension
/// AVFoundation can dispatch a container decoder from. Kept pure so the
/// extension logic is unit-testable without a live player or a real file.
enum VideoTempFilename {
    /// Container extensions AVFoundation can dispatch on directly. Lower-cased
    /// membership check, so a filename's own "MOV" matches too.
    static let recognizedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "3gp", "3g2",
        "m2ts", "mts", "ts", "webm", "mpg", "mpeg", "wmv", "hevc",
    ]

    /// Used when neither the asset's filename nor its reported container type
    /// names a recognized extension. `.mov` is the right default for this
    /// library's current videos (Live Photo MOV clips).
    static let fallbackExtension = "mov"

    static func isRecognizedVideoExtension(_ ext: String) -> Bool {
        recognizedExtensions.contains(ext.lowercased())
    }

    /// Whether `path`'s own extension is already a recognized video
    /// container, so the file can be handed to `AVURLAsset` as-is without a
    /// re-extensioned copy. The core's download temp file is extensionless,
    /// so this is normally `false` and a copy is made.
    static func pathHasRecognizedExtension(_ path: String) -> Bool {
        isRecognizedVideoExtension((path as NSString).pathExtension)
    }

    /// A single-path-component filename carrying a video-container extension
    /// for `asset`'s downloaded original.
    ///
    /// Preference order: the asset's own filename extension when it is already
    /// a recognized container (the real name as stored on the NAS is the best
    /// signal), then the NAS-reported `containerType` (e.g. "mov"), then a
    /// `.mov` fallback. Reuses `QuickLookFilename.derive` for its defensive
    /// base-name sanitization (no `/`, no `..`, never empty), then repairs the
    /// extension for the video case: a Live Photo whose asset filename is the
    /// still's `.heic` would otherwise get a non-video extension.
    static func derive(for asset: Asset) -> String {
        let candidate = QuickLookFilename.derive(for: asset)
        let ext = (candidate as NSString).pathExtension
        if isRecognizedVideoExtension(ext) { return candidate }
        let base = (candidate as NSString).deletingPathExtension
        let container = asset.containerType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let chosen = isRecognizedVideoExtension(container) ? container : fallbackExtension
        return "\(base).\(chosen)"
    }
}

/// Hosts an `AVPlayerView` with Apple's own standard playback controls
/// (play/pause, scrubber, volume) plus a hidden error overlay shown when
/// playback cannot start. Read-only: never uploads or mutates anything, only
/// plays back a local file or (once a working Streaming method is found) a
/// remote URL.
final class VideoPlayerContainerView: NSView {
    let playerView: AVPlayerView = {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        return view
    }()

    private let errorIcon: NSImageView = {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .systemYellow
        icon.translatesAutoresizingMaskIntoConstraints = false
        return icon
    }()

    private let errorTitle: NSTextField = {
        let label = NSTextField(labelWithString: "Could not play this video")
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let errorMessage: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = NSColor(white: 1, alpha: 0.7)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private lazy var errorStack: NSStackView = {
        let stack = NSStackView(views: [errorIcon, errorTitle, errorMessage])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isHidden = true
        stack.setAccessibilityIdentifier("detail.video.error")
        return stack
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(playerView)
        addSubview(errorStack)
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: topAnchor),
            playerView.bottomAnchor.constraint(equalTo: bottomAnchor),
            errorStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            errorStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            errorStack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Shows the error overlay with `message`. Safe to call repeatedly.
    func showError(_ message: String) {
        errorMessage.stringValue = message
        errorStack.isHidden = false
    }

    /// Hides the error overlay (a fresh load starting, or playback becoming
    /// ready).
    func hideError() {
        errorStack.isHidden = true
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
/// see the file header), re-extensions a local file so AVFoundation can
/// recognize the container, then plays it with `AVPlayerView`'s own standard
/// transport controls. Any failure to start playback shows a visible error
/// overlay rather than a silent black frame.
///
/// Read-only: never uploads, edits, or deletes anything on the NAS.
struct DetailVideoPlayerView: NSViewRepresentable {
    let asset: Asset
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache
    let synoToken: String?

    /// Ensures a `.localFile` playback source points at a file whose
    /// extension AVFoundation can dispatch a container decoder from. The
    /// core's download temp file is extensionless; an unrecognized container
    /// is exactly the "silent black frame" case. Copies the file into `cache`
    /// under a video-extensioned name derived from the asset and returns a
    /// source pointing at the copy. A `.url` source, or a local path that
    /// already carries a recognized video extension, passes through unchanged;
    /// a copy failure also passes the original through (via `TempFileCache`'s
    /// own fallback) so a best-effort playback attempt still happens.
    static func preparedSource(
        from source: VideoPlaybackSource, asset: Asset, cache: TempFileCache
    ) async -> VideoPlaybackSource {
        guard case .localFile(let path) = source else { return source }
        if VideoTempFilename.pathHasRecognizedExtension(path) { return source }
        let filename = VideoTempFilename.derive(for: asset)
        let url = await cache.store(path: path, preferredFilename: filename)
        return .localFile(path: url.path)
    }

    /// A short, human-readable failure line for the error overlay. A
    /// `CoreError` already carries a user-facing message; anything else gets
    /// a plain fallback.
    static func message(for error: Error) -> String {
        if let core = error as? CoreError { return core.userMessage }
        return "This video could not be played."
    }

    func makeNSView(context: Context) -> VideoPlayerContainerView {
        VideoPlayerContainerView()
    }

    func updateNSView(_ nsView: VideoPlayerContainerView, context: Context) {
        guard context.coordinator.lastAssetId != asset.id else { return }
        context.coordinator.lastAssetId = asset.id
        // Stop whatever the previous asset was playing before loading the
        // next one, matching Photos' own behavior of not letting a previous
        // video keep playing audio once you've paged away. Drop the old
        // status observation too, so a late failure callback for the previous
        // item never flashes an error over the new one.
        context.coordinator.statusObservation?.invalidate()
        context.coordinator.statusObservation = nil
        nsView.playerView.player?.pause()
        nsView.playerView.player = nil
        nsView.hideError()

        let a = asset, s = space, c = client, token = synoToken
        let cache = self.cache
        let coordinator = context.coordinator
        Task {
            do {
                let source = try await c.videoPlaybackSource(space: s, asset: a)
                guard coordinator.lastAssetId == a.id else { return }
                let playable = await DetailVideoPlayerView.preparedSource(
                    from: source, asset: a, cache: cache)
                guard coordinator.lastAssetId == a.id else { return }
                let urlAsset = VideoPlaybackAssetBuilder.makeAsset(source: playable, synoToken: token)
                let item = AVPlayerItem(asset: urlAsset)
                let player = AVPlayer(playerItem: item)
                await MainActor.run {
                    guard coordinator.lastAssetId == a.id else { return }
                    nsView.hideError()
                    coordinator.observeStatus(of: item, in: nsView)
                    nsView.playerView.player = player
                    player.play()
                }
            } catch {
                await MainActor.run {
                    guard coordinator.lastAssetId == a.id else { return }
                    nsView.showError(DetailVideoPlayerView.message(for: error))
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: VideoPlayerContainerView, coordinator: Coordinator) {
        coordinator.statusObservation?.invalidate()
        coordinator.statusObservation = nil
        nsView.playerView.player?.pause()
        nsView.playerView.player = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks which asset the hosted player is currently showing, the same
    /// pattern `DetailQuickLookView.Coordinator` uses, so a redundant
    /// SwiftUI re-render (paging did not actually change) does not restart
    /// playback or re-download the file. Also owns the KVO observation that
    /// turns an `AVPlayerItem` playback failure into a visible error.
    final class Coordinator {
        var lastAssetId: Int64?
        var statusObservation: NSKeyValueObservation?

        /// Observes `item.status`: a `.failed` transition (undecodable or
        /// unreachable media) shows the error overlay, `.readyToPlay` hides
        /// it. KVO callbacks can arrive off the main thread, so UI work is
        /// hopped to main.
        func observeStatus(of item: AVPlayerItem, in view: VideoPlayerContainerView) {
            statusObservation?.invalidate()
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak view] observedItem, _ in
                let status = observedItem.status
                let errorText = observedItem.error?.localizedDescription
                DispatchQueue.main.async {
                    guard let view else { return }
                    switch status {
                    case .failed:
                        view.showError(errorText ?? "This video could not be played.")
                    case .readyToPlay:
                        view.hideError()
                    default:
                        break
                    }
                }
            }
        }
    }
}
