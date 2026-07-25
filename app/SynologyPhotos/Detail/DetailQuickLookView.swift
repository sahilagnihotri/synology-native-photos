import SwiftUI
import AppKit
import PhotosCore

// Format support (read-only Phase 1):
//  - Photos and Live Photo stills are rendered from the downloaded original
//    with `NSImage`/ImageIO, which covers JPEG, HEIC, PNG, and most camera
//    RAW containers stock macOS ships a decoder for. The image is drawn
//    aspect-fit and centered, and the whole render path has three explicit
//    states (loading, loaded, failed) so a download or decode failure is
//    always visible, never a silent black frame.
//  - True videos (media_kind == video) do NOT come through here at all; they
//    take the `DetailVideoPlayerView` (AVPlayer) branch in `DetailViewerHost`.
//    A "live" item decodes as `MediaKind.unknown` and is a plain still on
//    disk (verified against the real NAS: IMG_1870's downloaded bytes were a
//    JPEG, not a video container), so it renders here exactly like a photo.
//  - Live Photos re-pairing (still + paired MOV into one PHLivePhoto) is
//    DEFERRED past Phase 1. The MVP previews the still and any paired video
//    as two separate originals; no attempt is made here to rejoin a pair.

/// Derives the filename an asset's downloaded original should carry on disk,
/// so the temp copy handed to the image loader keeps the extension that
/// image/format dispatch relies on.
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
    ///    RAW variant vs MOV vs MP4 all matter, and only the original
    ///    filename actually distinguishes them).
    /// 2. A `mediaKind`-based fallback extension, when the filename has
    ///    none, so the loader still gets *a* usable extension rather than
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
///   cache's own copies are ever deleted. This is what the detail image
///   loader uses, since a correctly-extensioned filename decodes more
///   reliably and the core's own temp path has none.
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

/// The three explicit states the detail image renderer can be in. Making
/// these a first-class value (rather than an implicit "there might be an
/// image or there might not") is what guarantees a failure surfaces as a
/// visible message instead of a silent black frame.
enum DetailImageState: Equatable {
    case loading
    case loaded(NSImage)
    case failed(String)

    static func == (lhs: DetailImageState, rhs: DetailImageState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading): return true
        case let (.loaded(a), .loaded(b)): return a === b
        case let (.failed(a), .failed(b)): return a == b
        default: return false
        }
    }
}

/// Drives the detail image render through its three states, cache-aware. Kept
/// free of any direct network/SwiftUI dependency by taking its load steps as
/// injected closures (the production wiring hands it `OriginalImageCache`'s
/// RAM/disk/network path), so the state machine (starts loading, moves to
/// loaded on a valid image, moves to failed on a thrown error or an undecodable
/// file) is unit-testable without a live NAS or a real image on disk.
@MainActor
@Observable
final class DetailImageLoader {
    private(set) var state: DetailImageState = .loading

    /// A grid thumbnail for the current asset, shown scaled up as an immediate
    /// placeholder while the full original loads, so paging never flashes an
    /// empty pane for a photo whose thumbnail is already cached. Nil when no
    /// thumbnail is cached, in which case the view falls back to a spinner.
    private(set) var placeholder: NSImage?

    /// A near-full-resolution decode, loaded lazily only once the user zooms
    /// past fit so a zoomed-in photo stays crisp. Nil until then, and reset on
    /// every new photo.
    private(set) var fullResolution: NSImage?

    private let loadDisplay: (Asset, Space) async throws -> NSImage?
    private let loadFull: (Asset, Space) async throws -> NSImage?
    private let placeholderFor: (Asset) -> NSImage?

    init(
        loadDisplay: @escaping (Asset, Space) async throws -> NSImage?,
        loadFull: @escaping (Asset, Space) async throws -> NSImage? = { _, _ in nil },
        placeholderFor: @escaping (Asset) -> NSImage? = { _ in nil }
    ) {
        self.loadDisplay = loadDisplay
        self.loadFull = loadFull
        self.placeholderFor = placeholderFor
    }

    /// Runs one load-and-decode cycle for `asset`, publishing `.loading` first
    /// (with the cached grid thumbnail as an immediate placeholder if one
    /// exists) so a re-attempt or a paging move always shows progress rather
    /// than the previous photo frozen underneath. The heavy work (network on a
    /// cache miss, decode) is inside `loadDisplay`, which returns the already
    /// downsampled image; a `nil` return means the bytes could not be decoded.
    func load(asset: Asset, space: Space) async {
        fullResolution = nil
        placeholder = placeholderFor(asset)
        state = .loading
        do {
            if let image = try await loadDisplay(asset, space) {
                state = .loaded(image)
            } else {
                state = .failed("This file could not be opened as an image.")
            }
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Loads the near-full-resolution decode once (idempotent), for when the
    /// user magnifies past fit. Served from cache on a disk/RAM hit, so it is
    /// cheap after the first open and never re-downloads. A failure is silently
    /// ignored: the downsampled image stays on screen (just less crisp when
    /// zoomed), which beats replacing a working view with an error.
    func loadFullResolutionIfNeeded(asset: Asset, space: Space) async {
        guard fullResolution == nil else { return }
        if let image = try? await loadFull(asset, space) {
            fullResolution = image
        }
    }

    /// The best image to display right now: the full-resolution decode if it
    /// has loaded (zoomed in), else the downsampled image from `state`.
    var displayImage: NSImage? {
        if let fullResolution { return fullResolution }
        if case .loaded(let image) = state { return image }
        return nil
    }

    /// A short, human-readable failure line. A `CoreError` already carries a
    /// user-facing message; anything else gets a plain fallback.
    static func message(for error: Error) -> String {
        if let core = error as? CoreError { return core.userMessage }
        return "Could not load this photo."
    }

    /// Pure display-target policy: the downsample max-pixel derived from a
    /// screen's native pixel resolution (points times backing scale). Bounded
    /// so a photo is crisp at fit while the decode stays far cheaper than a
    /// full original, and so an external 6K/8K display does not push every
    /// decode to an enormous bitmap. Split out as a pure function so it is
    /// testable without an actual screen.
    static func displayMaxPixel(screenMaxDimension: CGFloat?, scale: CGFloat?) -> Int {
        let dimension = screenMaxDimension ?? 1600
        let backing = scale ?? 2
        return min(max(Int(dimension * backing), 1024), 4096)
    }

    /// The display target for the machine's main screen, or a sane default on a
    /// headless host.
    static func displayMaxPixel() -> Int {
        let screen = NSScreen.main
        let maxDim = screen.map { max($0.frame.width, $0.frame.height) }
        return displayMaxPixel(screenMaxDimension: maxDim, scale: screen?.backingScaleFactor)
    }
}

/// `NSScrollView` subclass that hosts an `NSImageView` and owns the zoom the
/// detail viewer's scroll/pinch magnify and reset-to-fit act on.
///
/// Zoom is plain AppKit scroll-view magnification (`allowsMagnification`)
/// around the fitted image view: at `fitScale` the image view fills the
/// viewport and the photo is drawn aspect-fit and centered; magnifying scales
/// that up and lets the user pan by scrolling, the same mechanism Preview.app
/// uses. No bytes are re-fetched at a higher resolution.
final class ZoomableImageScrollView: NSScrollView {
    let imageView = NSImageView()

    /// Called whenever the live magnification settles (a programmatic set, a
    /// double-click reset, or the end of a pinch gesture) so the SwiftUI
    /// zoom slider can reflect the current value.
    var onMagnificationChange: ((CGFloat) -> Void)?

    /// Double-click anywhere resets to fit, matching the spec's "double-click
    /// to reset". `numberOfClicksRequired = 2` means a single click is never
    /// intercepted by this recognizer.
    private var resetGesture: NSClickGestureRecognizer?

    /// Click-and-drag panning when zoomed in past fit. A gesture recognizer
    /// (rather than a `mouseDragged` override) so it fires anywhere over the
    /// image without fighting the document `NSImageView` for the responder
    /// chain, and so AppKit's own gesture arbitration keeps it from ever
    /// swallowing the double-click reset: a stationary double-click produces
    /// no translation, so this recognizer never begins for it. A primary
    /// button drag, not a two-finger trackpad scroll (which stays a
    /// scroll-wheel event the scroll view pans natively), is what drives it.
    private var panGesture: NSPanGestureRecognizer?

    init() {
        super.init(frame: .zero)
        allowsMagnification = true
        minMagnification = DetailZoomModel.fitScale
        maxMagnification = DetailZoomModel.maxScale
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.setAccessibilityIdentifier("detail.image")
        documentView = imageView
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        gesture.numberOfClicksRequired = 2
        addGestureRecognizer(gesture)
        resetGesture = gesture
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        panGesture = pan
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded),
            name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Keeps the fitted image view filling the viewport at 100%, from where
    /// magnification scales it. Done in response to the scroll view's own
    /// frame changing (a window resize) rather than inside a `layout()`
    /// override: mutating a subview's geometry from within the scroll view's
    /// layout pass is what produced the "-layoutSubtreeIfNeeded on a view
    /// which is already being laid out" warning, because it re-dirtied the
    /// document view mid-layout. Only re-sized while at fit, so a resize
    /// mid-zoom does not fight the user's current pan/zoom.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizeImageViewToFitIfNeeded()
    }

    /// Sets the fitted image view's frame to the current viewport size, but
    /// only when at fit and only when it actually differs, so a redundant
    /// same-value assignment never re-triggers layout.
    private func sizeImageViewToFitIfNeeded() {
        guard !DetailZoomModel.isZoomed(magnification) else { return }
        let target = NSRect(origin: .zero, size: bounds.size)
        if imageView.frame != target { imageView.frame = target }
    }

    /// Resets the current zoom to fit. `NSScrollView.magnification` is the
    /// live "current zoom" property scroll/pinch gestures write into
    /// directly; setting it back to `fitScale` is what resetting to fit
    /// means here. Both writes are deduplicated so a reset that is already at
    /// fit does no redundant work (and fires no spurious magnification
    /// callback).
    func resetZoom() {
        if magnification != DetailZoomModel.fitScale {
            magnification = DetailZoomModel.fitScale
        }
        let target = NSRect(origin: .zero, size: bounds.size)
        if imageView.frame != target { imageView.frame = target }
    }

    /// Clamps every programmatic magnification change through
    /// `DetailZoomModel.clamp` (the live pinch gesture is already bounded by
    /// `min`/`maxMagnification`), so the same fit..8x bound the model's tests
    /// verify is what the view enforces, and reports the settled value.
    override var magnification: CGFloat {
        get { super.magnification }
        set {
            super.magnification = DetailZoomModel.clamp(newValue)
            onMagnificationChange?(super.magnification)
        }
    }

    @objc private func handleDoubleClick() {
        resetZoom()
    }

    /// Pans the zoomed image by moving the clip view's origin opposite the
    /// drag, so the content follows the cursor (grab-and-drag). No-op unless
    /// actually zoomed past fit, matching the spec's "only pan when zoomed".
    ///
    /// The gesture's translation is read in this scroll view's own
    /// (un-magnified) coordinate space and divided by the magnification to
    /// convert screen points into clip-bounds units; the result is clamped
    /// through `constrainBoundsRect` so a drag can never scroll past the
    /// image edges. Translation is reset to zero each callback so successive
    /// events apply incremental deltas.
    @objc private func handlePan(_ gesture: NSPanGestureRecognizer) {
        guard DetailZoomModel.isZoomed(magnification) else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)
        guard translation != .zero else { return }
        let scale = max(magnification, 0.0001)
        var proposed = contentView.bounds
        proposed.origin.x -= translation.x / scale
        proposed.origin.y -= translation.y / scale
        let constrained = contentView.constrainBoundsRect(proposed)
        contentView.scroll(to: constrained.origin)
        reflectScrolledClipView(contentView)
    }

    @objc private func liveMagnifyEnded() {
        onMagnificationChange?(magnification)
    }
}

/// Hosts `ZoomableImageScrollView` and keeps the SwiftUI `magnification`
/// binding and the AppKit scroll view's live magnification in sync in both
/// directions: the toolbar slider drives the view, and a pinch or
/// double-click reset drives the slider back. Resets to fit whenever the
/// displayed asset changes.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let assetId: Int64
    @Binding var magnification: CGFloat

    func makeNSView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView()
    }

    func updateNSView(_ nsView: ZoomableImageScrollView, context: Context) {
        // Reflect a pinch/double-click back into the binding, guarded so the
        // programmatic sets below (which also fire this callback) do not loop.
        nsView.onMagnificationChange = { mag in
            guard !context.coordinator.isApplyingBinding else { return }
            if abs(magnification - mag) > 0.0005 { magnification = mag }
        }

        if context.coordinator.lastAssetId != assetId {
            // A new photo (paging reuses this same NSView): swap the image
            // and reset zoom to fit, matching Photos' per-photo zoom reset.
            // The binding itself is reset to fit by `DetailViewerHost`'s
            // `onChange(of: currentIndex)`, so nothing writes the binding
            // here (writing it during a view update is what SwiftUI warns
            // about); the guard keeps `resetZoom`'s callback from doing so.
            context.coordinator.lastAssetId = assetId
            nsView.imageView.image = image
            context.coordinator.isApplyingBinding = true
            nsView.resetZoom()
            context.coordinator.isApplyingBinding = false
        } else {
            if nsView.imageView.image !== image { nsView.imageView.image = image }
            // Apply a slider-driven change from the binding into the view.
            if abs(nsView.magnification - magnification) > 0.0005 {
                context.coordinator.isApplyingBinding = true
                nsView.magnification = magnification
                context.coordinator.isApplyingBinding = false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks the shown asset (to reset zoom only on a real photo change, not
    /// every re-render) and guards the two-way magnification sync against a
    /// feedback loop.
    final class Coordinator {
        var lastAssetId: Int64?
        var isApplyingBinding = false
    }
}

/// Full-size photo detail view: resolves the original for `asset` through the
/// two-tier `OriginalImageCache` (RAM decode, then disk original, then a single
/// network `downloadOriginal` on a cache miss), decodes it downsampled to the
/// display size, and renders it aspect-fit and centered with scroll/pinch zoom.
/// Zooming past fit lazily loads a near-full-resolution decode so the zoomed
/// image stays crisp.
///
/// States, so a failure is never a silent black frame and paging never flashes
/// blank: while loading it shows the already-cached grid thumbnail scaled up
/// (or a spinner when there is none), the zoomable image once loaded, and a
/// labeled error with a Retry button if the load or decode fails.
///
/// Read-only: this view only ever downloads and previews. It never uploads,
/// edits, or deletes anything on the NAS.
struct DetailQuickLookView: View {
    let asset: Asset
    let space: Space
    let client: PhotosCoreClient
    let originalCache: OriginalImageCache
    let thumbnailCache: ThumbnailCache
    @Binding var magnification: CGFloat

    @State private var loader: DetailImageLoader

    init(
        asset: Asset,
        space: Space,
        client: PhotosCoreClient,
        originalCache: OriginalImageCache,
        thumbnailCache: ThumbnailCache,
        magnification: Binding<CGFloat>
    ) {
        self.asset = asset
        self.space = space
        self.client = client
        self.originalCache = originalCache
        self.thumbnailCache = thumbnailCache
        _magnification = magnification
        // Computed once per view instance (the detail viewer reuses one
        // instance across paging), so the RAM cache key stays stable.
        let maxPixel = DetailImageLoader.displayMaxPixel()
        _loader = State(initialValue: DetailImageLoader(
            loadDisplay: { a, s in
                // Must pass a.unitId, not a.id: the download endpoint keys on
                // unit_id the same way the thumbnail endpoint does. The cache
                // only invokes this download on a disk miss.
                try await originalCache.displayImage(
                    cacheKey: a.cacheKey,
                    maxPixel: maxPixel,
                    preferredFilename: QuickLookFilename.derive(for: a),
                    download: { try await client.downloadOriginal(space: s, unitId: a.unitId, cacheKey: a.cacheKey) })
            },
            loadFull: { a, s in
                try await originalCache.fullImage(
                    cacheKey: a.cacheKey,
                    preferredFilename: QuickLookFilename.derive(for: a),
                    download: { try await client.downloadOriginal(space: s, unitId: a.unitId, cacheKey: a.cacheKey) })
            },
            placeholderFor: { a in Self.placeholder(for: a, thumbnailCache: thumbnailCache) }))
    }

    /// The best already-cached grid thumbnail for `asset`, largest size first,
    /// as an `NSImage` placeholder. A synchronous memory-tier peek only (no
    /// fetch, no actor hop), so it is safe to evaluate while building the view.
    private static func placeholder(for asset: Asset, thumbnailCache: ThumbnailCache) -> NSImage? {
        for size in [ThumbnailSize.xl, .m, .sm] {
            let key = ThumbKey(assetId: asset.id, size: size, cacheKey: asset.cacheKey)
            if let cg = thumbnailCache.peekMemory(key) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return nil
    }

    var body: some View {
        Group {
            switch loader.state {
            case .loading:
                if let placeholder = loader.placeholder {
                    placeholderView(placeholder)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("detail.loading")
                }
            case .loaded:
                if let image = loader.displayImage {
                    ZoomableImageView(image: image, assetId: asset.id, magnification: $magnification)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .failed(let message):
                failureView(message)
            }
        }
        // `.task(id:)` cancels and restarts whenever the shown asset changes,
        // so paging Left/Right reloads the new photo (and shows its placeholder)
        // even though this view instance is reused.
        .task(id: asset.id) {
            await loader.load(asset: asset, space: space)
        }
        .onChange(of: magnification) { _, newValue in
            // Only fetch the crisp full-resolution decode once the user has
            // actually zoomed past fit; the initial open stays on the fast
            // downsampled image.
            guard DetailZoomModel.isZoomed(newValue) else { return }
            Task { await loader.loadFullResolutionIfNeeded(asset: asset, space: space) }
        }
    }

    /// The cached grid thumbnail shown scaled to fit, with a small spinner
    /// over it, while the full original loads. Upscaling a small thumbnail is
    /// deliberately soft, but a soft preview that appears instantly beats a
    /// blank pane, and it is replaced by the full decode the moment it lands.
    private func placeholderView(_ image: NSImage) -> some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("detail.placeholder")
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
            Text("Could not load this photo")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button {
                Task { await loader.load(asset: asset, space: space) }
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("detail.retry")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("detail.failed")
    }
}

/// Photos-style chrome around the detail image: the photo filling a dark
/// pane, a floating top bar (Back, zoom slider, info toggle), Left/Right
/// paging, and Cmd+Up / Escape to return to the grid. `currentIndex` is a
/// binding rather than owned state so the caller can read where paging left
/// off, e.g. to keep the grid's own selection in sync.
///
/// Takes `assetCount` plus an `assetAt` lookup rather than a materialized
/// `[Asset]` array: the detail viewer can be opened against the same
/// 20k-100k-item space the grid windows over, and paging through it must not
/// force every asset into memory just to know how far Right can go. `assetAt`
/// returning `nil` for the current index (a page not loaded yet) renders
/// nothing for that frame rather than crashing; `WindowedDataSource` schedules
/// the load as a side effect of being asked, so a follow-up re-render once it
/// resolves is expected to show the photo.
struct DetailViewerHost: View {
    let assetCount: Int
    let assetAt: (Int) -> Asset?
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache
    /// Two-tier cache of downloaded originals (RAM decode + on-disk bytes),
    /// shared by the photo and video detail paths so a re-open is instant and
    /// never re-downloads.
    let originalCache: OriginalImageCache
    /// The grid's thumbnail cache, consulted for an instant placeholder while
    /// a full original loads.
    let thumbnailCache: ThumbnailCache
    /// The current session's `syno_token`, forwarded to
    /// `DetailVideoPlayerView` for a future streaming-URL playback source
    /// (see that file's header comment); unused on the current
    /// download-then-play-local path, but threaded through now so no
    /// further plumbing is needed once a working Streaming method is found.
    let synoToken: String?
    @Binding var currentIndex: Int
    let onClose: () -> Void
    /// Runs the everyday delete for the currently shown photo. Wired by
    /// `LibraryView` to the SAME `DeleteController` flow the grid uses, so a
    /// delete from full-photo view shows the identical confirm and, on
    /// success, removes the item from the library and closes the viewer.
    let onDelete: (Asset) -> Void
    /// Opens the non-destructive editor for the currently shown photo. Wired by
    /// `LibraryView` to present `PhotoEditorView`; saving there uploads a NEW
    /// photo and leaves the original untouched.
    let onEdit: (Asset) -> Void

    /// Info panel visibility, toggled by the "i" button or Cmd-I. Not reset
    /// on paging: Photos keeps the info panel open across Left/Right moves.
    @State private var isShowingInfo = false

    /// The current photo's zoom, shared between the toolbar slider and the
    /// image view. Reset to fit on every paging move so a new photo always
    /// opens fitted, matching Photos.
    @State private var magnification: CGFloat = DetailZoomModel.fitScale

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            if let asset = assetAt(currentIndex) {
                // Only a true video (media_kind == video) takes the AVPlayer
                // path. A "live" item (Live Photo still) decodes as
                // MediaKind.unknown and is a plain still on disk, so it keeps
                // going through the image renderer exactly like an ordinary
                // photo rather than trying to play a JPEG as a video.
                Group {
                    if asset.mediaKind == .video {
                        DetailVideoPlayerView(
                            asset: asset,
                            space: space,
                            client: client,
                            cache: cache,
                            originalCache: originalCache,
                            synoToken: synoToken)
                    } else {
                        DetailQuickLookView(
                            asset: asset,
                            space: space,
                            client: client,
                            originalCache: originalCache,
                            thumbnailCache: thumbnailCache,
                            magnification: $magnification)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isShowingInfo {
                    HStack {
                        Spacer()
                        AssetInfoPanelView(fields: AssetInfoFields(asset: asset))
                            .padding(.top, 64)
                            .padding(.trailing, 16)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                topChrome(for: asset)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isShowingInfo)
        .onChange(of: currentIndex) { _, _ in
            // Every paging move opens the next photo fitted, never carrying a
            // previous zoom over to a random crop of a photo never zoomed.
            magnification = DetailZoomModel.fitScale
        }
        .background(KeyCatcher { event in
            handleKey(event)
        })
        .accessibilityIdentifier("detail.viewer")
    }

    /// The floating top bar: leading Back, a centered zoom slider (photos
    /// only), and a trailing info toggle. Semi-transparent material so the
    /// image reads through it, matching Apple's own detail chrome.
    private func topChrome(for asset: Asset) -> some View {
        HStack(spacing: 16) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.back")
            .accessibilityLabel("Back")

            Spacer()

            if asset.mediaKind != .video {
                HStack(spacing: 8) {
                    Image(systemName: "minus.magnifyingglass")
                        .foregroundStyle(.white.opacity(0.8))
                    Slider(
                        value: $magnification,
                        in: DetailZoomModel.fitScale...DetailZoomModel.maxScale)
                        .frame(width: 160)
                        .accessibilityIdentifier("detail.zoom.slider")
                    Image(systemName: "plus.magnifyingglass")
                        .foregroundStyle(.white.opacity(0.8))
                }
            }

            Spacer()

            // Edit is offered for still photos only; a true video has no crop/
            // rotate editor. Saving an edit uploads a NEW photo and never
            // changes the original (see `PhotoEditorView`).
            if asset.mediaKind != .video {
                Button {
                    onEdit(asset)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("detail.edit")
                .accessibilityLabel("Edit")
            }

            Button {
                requestDeleteCurrent()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.delete")
            .accessibilityLabel("Delete")

            Button {
                isShowingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("detail.infobutton")
            .accessibilityLabel("Info")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        guard let action = DetailKeyMapper.action(for: event) else { return false }
        switch action {
        case .close:
            // Escape, Space, or Cmd+Up returns to the grid, the mirror of the
            // grid's Cmd+Down "open into detail".
            onClose()
            return true
        case .previous:
            if let target = DetailPagingModel.index(before: currentIndex) {
                currentIndex = target
            }
            return true
        case .next:
            if let target = DetailPagingModel.index(after: currentIndex, count: assetCount) {
                currentIndex = target
            }
            return true
        case .toggleInfo:
            isShowingInfo.toggle()
            return true
        case .delete:
            requestDeleteCurrent()
            return true
        }
    }

    /// Routes a delete gesture (toolbar Delete button or Delete/Cmd-Delete
    /// key) for the currently shown photo into the injected `onDelete`, the
    /// SAME `DeleteController` flow the grid uses. A no-op when the current
    /// index has no loaded asset (a page not yet resolved), so a keypress
    /// against a blank frame can never raise an empty confirm.
    private func requestDeleteCurrent() {
        guard let asset = assetAt(currentIndex) else { return }
        onDelete(asset)
    }
}

/// The detail viewer's info panel content, read straight off `Asset` via
/// `AssetInfoFields` and laid out to resemble Synology's own Information
/// panel: the filename and a star rating up top, then the basics
/// (date/dimensions/size), an optional caption, an EXIF group, and, for
/// videos, a playback group. Every field is drawn only when
/// `AssetInfoFields` carries a value for it, so a screenshot with no EXIF or
/// an unrated photo simply shows fewer rows rather than blank ones.
struct AssetInfoPanelView: View {
    let fields: AssetInfoFields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fields.filename)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("info.filename")

            if let stars = fields.starRating {
                Text(stars)
                    .font(.title3)
                    .accessibilityIdentifier("info.rating")
                    .accessibilityLabel("Rating")
            }

            Divider()

            row(label: fields.dateLabel, value: fields.dateValue, identifier: "info.date")
            if let dimensions = fields.dimensions {
                row(label: "Dimensions", value: dimensions, identifier: "info.dimensions")
            }
            if let fileSize = fields.fileSize {
                row(label: "File Size", value: fileSize, identifier: "info.filesize")
            }

            if let description = fields.description {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(description)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("info.description")
            }

            if fields.hasExif {
                Divider()
                if let camera = fields.camera {
                    row(label: "Camera", value: camera, identifier: "info.camera")
                }
                if let lens = fields.lens {
                    row(label: "Lens", value: lens, identifier: "info.lens")
                }
                if let aperture = fields.aperture {
                    row(label: "Aperture", value: aperture, identifier: "info.aperture")
                }
                if let exposureTime = fields.exposureTime {
                    row(label: "Exposure", value: exposureTime, identifier: "info.exposure")
                }
                if let focalLength = fields.focalLength {
                    row(label: "Focal Length", value: focalLength, identifier: "info.focallength")
                }
                if let iso = fields.iso {
                    row(label: "ISO", value: iso, identifier: "info.iso")
                }
            }

            if fields.hasVideoDetails {
                Divider()
                if let duration = fields.duration {
                    row(label: "Duration", value: duration, identifier: "info.duration")
                }
                if let framerate = fields.framerate {
                    row(label: "Frame Rate", value: framerate, identifier: "info.framerate")
                }
                if let videoCodec = fields.videoCodec {
                    row(label: "Codec", value: videoCodec, identifier: "info.codec")
                }
                if let containerType = fields.containerType {
                    row(label: "Container", value: containerType, identifier: "info.container")
                }
            }
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
        .accessibilityIdentifier("detail.infopanel")
    }

    private func row(label: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Invisible `NSView` whose only purpose is becoming first responder so
/// `onKey` sees the detail viewer's Escape/arrow/space/Cmd-key presses.
/// SwiftUI has no built-in "capture this specific key regardless of focus"
/// primitive for an `NSViewRepresentable`-hosted view; this sits behind the
/// content in the z-order and asks for first responder once inserted, so key
/// events reach it via the normal responder chain when the content itself
/// does not consume them.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> KeyCatcherView {
        let view = KeyCatcherView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: KeyCatcherView, context: Context) {
        nsView.onKey = onKey
        DispatchQueue.main.async {
            if nsView.window?.firstResponder !== nsView {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class KeyCatcherView: NSView {
    var onKey: ((NSEvent) -> Bool)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}
