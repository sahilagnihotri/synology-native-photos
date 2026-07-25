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

/// `NSScrollView` subclass that hosts `QLPreviewView` and owns the zoom
/// state the detail viewer's scroll/pinch magnify + reset-to-fit act on.
///
/// Zooming the detail image is implemented as plain AppKit scroll-view
/// magnification (`allowsMagnification`) around the already-loaded
/// `QLPreviewView`, rather than anything QuickLook-specific: `QLPreviewView`
/// keeps its own full format dispatch (RAW/HEIC/video) completely
/// untouched, this class only decides how large its frame is drawn and lets
/// the user pan by scrolling once magnified, exactly the same mechanism
/// Preview.app and Xcode's own asset viewers use. No bytes are re-fetched
/// for a higher-resolution image: this magnifies whatever `QLPreviewView`
/// already rendered.
final class ZoomableQuickLookScrollView: NSScrollView {
    let previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()

    /// Double-click anywhere in the zoomed content resets to fit, matching
    /// the spec's "a way to reset to fit (double-click or a fit button)".
    /// `numberOfClicksRequired = 2` means a single click (which QuickLook
    /// itself may want for e.g. video scrubber controls) is never
    /// intercepted by this recognizer.
    private var resetGesture: NSClickGestureRecognizer?

    init() {
        super.init(frame: .zero)
        allowsMagnification = true
        minMagnification = DetailZoomModel.fitScale
        maxMagnification = DetailZoomModel.maxScale
        hasHorizontalScroller = false
        hasVerticalScroller = false
        drawsBackground = false
        previewView.setAccessibilityIdentifier("detail.quicklook")
        documentView = previewView
        let gesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick))
        gesture.numberOfClicksRequired = 2
        addGestureRecognizer(gesture)
        resetGesture = gesture
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    /// Resets the current zoom to fit, e.g. after paging to a new asset or
    /// on a double-click. `NSScrollView.magnification` is the live "current
    /// zoom" property scroll/pinch gestures already write into directly;
    /// setting it back to `DetailZoomModel.fitScale` is exactly what
    /// resetting to fit means here, there is no separate stored "fit" state
    /// to reconcile.
    func resetZoom() {
        magnification = DetailZoomModel.fitScale
    }

    /// Clamps every magnification change (scroll-wheel, pinch, or the
    /// system's own momentum) through `DetailZoomModel.clamp`, so the same
    /// fit..8x bound the model's tests verify is what the live view
    /// actually enforces, not a second, undocumented copy of the range.
    override var magnification: CGFloat {
        get { super.magnification }
        set { super.magnification = DetailZoomModel.clamp(newValue) }
    }

    @objc private func handleDoubleClick() {
        resetZoom()
    }
}

/// Full-size photo/video detail view: downloads the original for `asset`
/// (via `PhotosCoreClient.downloadOriginal`, Task 40 -> 37) into a
/// count-bounded temp cache, then previews it with QuickLook.
///
/// Read-only: this view only ever downloads and previews. It never uploads,
/// edits, or deletes anything on the NAS, selecting a grid item and
/// opening detail cannot mutate NAS state.
///
/// Wrapped in `ZoomableQuickLookScrollView` (see above) so scroll/pinch can
/// magnify the photo itself, with click-drag pan once zoomed (the scroll
/// view's own natural behavior above `fitScale`) and a double-click reset.
/// Left/Right paging keeps working at any zoom level: `DetailViewerHost`'s
/// key handling pages regardless of the current magnification, matching
/// Photos' own choice to keep arrow keys as paging and zoom as a
/// trackpad/scroll-only gesture.
struct DetailQuickLookView: NSViewRepresentable {
    let asset: Asset
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache

    func makeNSView(context: Context) -> ZoomableQuickLookScrollView {
        ZoomableQuickLookScrollView()
    }

    func updateNSView(_ nsView: ZoomableQuickLookScrollView, context: Context) {
        // A new asset (paging Left/Right reuses this same NSView instance,
        // SwiftUI does not re-create it) always resets zoom back to fit:
        // carrying a zoomed-in scale over to the next photo would leave the
        // user looking at a random crop of a photo they never zoomed
        // themselves, matching Photos' own behavior of resetting zoom per
        // photo.
        if context.coordinator.lastAssetId != asset.id {
            context.coordinator.lastAssetId = asset.id
            nsView.resetZoom()
        }

        let a = asset, s = space, c = client, tc = cache
        Task {
            do {
                // Must pass a.unitId, not a.id: the download endpoint keys
                // on unit_id the same way the thumbnail endpoint does.
                let downloadedPath = try await c.downloadOriginal(
                    space: s, unitId: a.unitId, cacheKey: a.cacheKey)
                let filename = QuickLookFilename.derive(for: a)
                let url = await tc.store(path: downloadedPath, preferredFilename: filename)
                await MainActor.run { nsView.previewView.previewItem = url as NSURL }
            } catch {
                // Read-only: on failure, leave the preview empty; no
                // mutation of the NAS is ever attempted on this path.
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Tracks which asset the hosted view is currently showing, purely so
    /// `updateNSView` can tell "this is the same photo, a redundant SwiftUI
    /// re-render" apart from "this is a new photo, reset the zoom", without
    /// resetting on every single body re-evaluation.
    final class Coordinator {
        var lastAssetId: Int64?
    }
}

/// Photos-style chrome around `DetailQuickLookView`: the photo centered on
/// a dimmed backdrop, Left/Right paging to the previous/next asset, Escape
/// closes. `currentIndex` is a binding rather than owned state so the
/// caller (the sheet's presenter) can read where paging left off, e.g. to
/// keep the grid's own selection in sync.
///
/// Takes `assetCount` plus an `assetAt` lookup rather than a materialized
/// `[Asset]` array: the detail viewer can be opened against the same
/// 20k-100k-item space the grid windows over, and paging through it must
/// not force every asset into memory just to know how far Right can go.
/// `assetAt` returning `nil` for the current index (a page not loaded yet)
/// renders nothing for that frame rather than crashing; `WindowedDataSource`
/// schedules the load as a side effect of being asked, so a follow-up
/// re-render once it resolves is expected to show the photo.
///
/// Minimal chrome by design (per the spec: "chrome minimal"): no toolbar of
/// its own, just the image and the paging affordance built into the key
/// handling.
struct DetailViewerHost: View {
    let assetCount: Int
    let assetAt: (Int) -> Asset?
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache
    @Binding var currentIndex: Int
    let onClose: () -> Void

    /// Info panel visibility, toggled by the "i" button or Cmd-I. Not reset
    /// on paging: Photos keeps the info panel open across Left/Right moves
    /// so browsing a sequence of photos with metadata visible does not
    /// require re-opening the panel on every single one.
    @State private var isShowingInfo = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.9).ignoresSafeArea()
            if let asset = assetAt(currentIndex) {
                DetailQuickLookView(
                    asset: asset,
                    space: space,
                    client: client,
                    cache: cache)
                .padding(24)
                if isShowingInfo {
                    HStack {
                        Spacer()
                        AssetInfoPanelView(fields: AssetInfoFields(asset: asset))
                            .padding(.top, 24)
                            .padding(.trailing, 24)
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            Button {
                isShowingInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.4), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(16)
            .accessibilityIdentifier("detail.infobutton")
            .accessibilityLabel("Info")
        }
        .animation(.easeInOut(duration: 0.15), value: isShowingInfo)
        .background(KeyCatcher { event in
            handleKey(event)
        })
        .accessibilityIdentifier("detail.viewer")
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case KeyCode.escape:
            onClose()
            return true
        case KeyCode.leftArrow:
            if let target = DetailPagingModel.index(before: currentIndex) {
                currentIndex = target
            }
            return true
        case KeyCode.rightArrow:
            if let target = DetailPagingModel.index(after: currentIndex, count: assetCount) {
                currentIndex = target
            }
            return true
        case KeyCode.space:
            onClose()
            return true
        case KeyCode.i where event.modifierFlags.contains(.command):
            isShowingInfo.toggle()
            return true
        default:
            return false
        }
    }
}

/// The detail viewer's info panel content: date, filename, dimensions, and
/// file size, read straight off `Asset` via `AssetInfoFields`. Per the
/// brief, camera/EXIF and location are not shown here since neither is a
/// field the core's `Asset` model or any read-only API call currently
/// exposes per-asset (see `AssetInfoFormatter`'s doc comment); a plain
/// note says so instead of a blank or invented field, and it is logged as
/// a follow-up (see the report/TODO) rather than blocking this panel.
struct AssetInfoPanelView: View {
    let fields: AssetInfoFields

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(fields.filename)
                .font(.headline)
                .lineLimit(2)
                .accessibilityIdentifier("info.filename")

            Divider()

            row(label: fields.dateLabel, value: fields.dateValue, identifier: "info.date")
            if let dimensions = fields.dimensions {
                row(label: "Dimensions", value: dimensions, identifier: "info.dimensions")
            }
            if let fileSize = fields.fileSize {
                row(label: "File Size", value: fileSize, identifier: "info.filesize")
            }

            Divider()

            Text(AssetInfoFormatter.exifFollowUpNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("info.exifnote")
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
        }
        .accessibilityIdentifier(identifier)
    }
}

/// Invisible `NSView` whose only purpose is becoming first responder so
/// `onKey` sees the detail viewer's Escape/arrow/space presses. SwiftUI has
/// no built-in "capture this specific key regardless of focus" primitive
/// for an `NSViewRepresentable`-hosted view like `QLPreviewView`, which
/// wants keyboard focus for its own playback controls; this sits behind it
/// in the z-order and asks for first responder once inserted, so key
/// events reach it via the normal responder chain when the preview itself
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
