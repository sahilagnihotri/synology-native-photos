import AppKit
import PhotosCore

/// A single reusable grid cell.
///
/// The thumbnail load is asynchronous and the cell can be recycled by
/// `NSCollectionView` before that load finishes (fast scroll is the normal
/// case, not the edge case). `representedAssetId` is the guard against the
/// classic reuse bug: every `configure` call captures the asset id it was
/// called for, and the completion only paints the image if the cell is
/// still showing that same id when the load finishes. If the cell was
/// reused for a different asset in the meantime, the late image is dropped
/// silently rather than painted over the wrong photo.
final class PhotoCellView: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PhotoCellView")

    private let thumbView = NSImageView()

    /// The asset id this cell is currently configured to show, or -1 when
    /// idle (freshly created or just reset by `prepareForReuse`). A pending
    /// thumbnail load is only applied while it still matches this value.
    private(set) var representedAssetId: Int64 = -1

    /// The in-flight async load for the current configuration, if any.
    /// Cancelled on reuse and on every re-`configure` so a superseded load
    /// can never win a race against a newer one.
    private var loadTask: Task<Void, Never>?

    /// The exact key (asset, size) whose decoded image is currently painted
    /// into `thumbView`, or `nil` when nothing is painted yet (idle, reused,
    /// or still loading). Compared against the newly requested key on every
    /// `configure` call so a diffable snapshot re-apply that reconfigures a
    /// cell for the asset it is already showing can recognize that and skip
    /// touching the image entirely, rather than clearing then repainting the
    /// same pixels.
    private var displayedKey: ThumbKey?

    /// The image currently painted into the cell, if any. Internal (not
    /// private) purely so tests can observe whether a stale, late-arriving
    /// thumbnail load was actually dropped by the reuse guard rather than
    /// painted; production code never reads this, it only ever writes
    /// `thumbView.image`.
    var displayedImage: NSImage? { thumbView.image }

    override func loadView() {
        let container = NSView()
        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.translatesAutoresizingMaskIntoConstraints = false
        thumbView.wantsLayer = true
        thumbView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        container.addSubview(thumbView)
        NSLayoutConstraint.activate([
            thumbView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumbView.topAnchor.constraint(equalTo: container.topAnchor),
            thumbView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    /// Called by `NSCollectionView` right before this item is handed back
    /// out for a different index path. Cancels any pending thumbnail load
    /// and clears both the displayed image and the represented id
    /// immediately, so there is no window where the cell shows a stale
    /// image (or could still accept one from a load started for the
    /// previous asset).
    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        thumbView.image = nil
        representedAssetId = -1
        displayedKey = nil
    }

    /// Binds this cell to `asset` and kicks off its thumbnail load.
    ///
    /// A diffable snapshot re-apply reconfigures every visible cell even
    /// when the underlying row has not changed (identity is unchanged, the
    /// item provider still runs). `needsReload` below is the guard against
    /// that: when the cell is already showing exactly this asset at this
    /// size (same `ThumbKey`) and an image is already painted, this call is
    /// a complete no-op, no cancel, no nil, no reload, so a redundant
    /// reconfigure is invisible instead of a blank-then-repaint flash.
    ///
    /// When it genuinely is a new asset, `cache.peekMemory(_:)` is checked
    /// synchronously first. On a hit the decoded image is already sitting
    /// in the in-memory tier, so it is painted directly with no intermediate
    /// `nil`, no flash. Only a genuine miss falls back to clearing the image
    /// and awaiting the async load. Any load still pending from a previous
    /// configuration is cancelled first (covers reconfigure-in-place, not
    /// just reuse via `prepareForReuse`). The new load captures `targetId`
    /// and re-checks `representedAssetId == targetId` after the await
    /// resumes; if the cell moved on (reused for another asset, or
    /// reconfigured again for the same asset with a newer task) the result
    /// is discarded.
    @MainActor
    func configure(asset: Asset, space: Space, cache: ThumbnailCache) {
        let key = ThumbKey(assetId: asset.id, size: .sm, cacheKey: asset.cacheKey)
        if !Self.needsReload(currentKey: displayedKey, requestedKey: key, hasImage: thumbView.image != nil) {
            return
        }

        representedAssetId = asset.id
        view.setAccessibilityIdentifier("grid.cell.\(asset.id)")
        loadTask?.cancel()

        if let cached = cache.peekMemory(key) {
            thumbView.image = NSImage(cgImage: cached, size: .zero)
            displayedKey = key
            loadTask = nil
            return
        }

        thumbView.image = nil
        displayedKey = nil
        let targetId = asset.id
        loadTask = Task { [weak self] in
            let cg = await cache.image(space: space, asset: asset, size: .sm)
            guard let self, self.representedAssetId == targetId, let cg else { return }
            self.thumbView.image = NSImage(cgImage: cg, size: .zero)
            self.displayedKey = key
        }
    }

    /// Pure decision extracted for testing: whether `configure` needs to do
    /// anything at all, given what the cell is currently showing versus what
    /// was just requested.
    ///
    /// `false` (no-op) only when the requested key exactly matches what is
    /// already displayed AND an image is actually on screen; a matching key
    /// with no image means a previous load is still pending or failed, so
    /// the load must still be (re)attempted.
    static func needsReload(currentKey: ThumbKey?, requestedKey: ThumbKey, hasImage: Bool) -> Bool {
        !(hasImage && currentKey == requestedKey)
    }
}
