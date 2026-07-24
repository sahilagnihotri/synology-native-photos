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
    }

    /// Binds this cell to `asset` and kicks off its thumbnail load.
    ///
    /// Any load still pending from a previous configuration is cancelled
    /// first (covers reconfigure-in-place, not just reuse via
    /// `prepareForReuse`). The new load captures `targetId` and re-checks
    /// `representedAssetId == targetId` after the await resumes; if the
    /// cell moved on (reused for another asset, or reconfigured again for
    /// the same asset with a newer task) the result is discarded.
    @MainActor
    func configure(asset: Asset, space: Space, cache: ThumbnailCache) {
        representedAssetId = asset.id
        view.setAccessibilityIdentifier("grid.cell.\(asset.id)")
        let targetId = asset.id
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let cg = await cache.image(space: space, asset: asset, size: .sm)
            guard let self, self.representedAssetId == targetId, let cg else { return }
            self.thumbView.image = NSImage(cgImage: cg, size: .zero)
        }
    }
}
