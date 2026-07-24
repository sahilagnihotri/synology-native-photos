import AppKit
import PhotosCore

/// Hosts the fast photo grid: an `NSCollectionView` with cell reuse, backed
/// by a diffable data source keyed on `AssetItemID` rather than raw index.
///
/// The grid never holds a 20k-100k library in memory itself. It reads only
/// the bounded, already-loaded slice sitting in `WindowedDataSource` and
/// asks that data source to fetch more as `NSCollectionViewPrefetching`
/// reports upcoming index paths. Cells resolve their own thumbnail through
/// `ThumbnailCache`; the controller's job is identity and layout, not image
/// loading.
@MainActor
final class PhotoGridController: NSViewController, NSCollectionViewPrefetching, NSCollectionViewDelegate {
    private let dataSource: WindowedDataSource
    private let cache: ThumbnailCache
    let collectionView = NSCollectionView()
    private var diffable: NSCollectionViewDiffableDataSource<Int, AssetItemID>?

    /// Set when `applySnapshot()` is called before `viewDidLoad()` has set up
    /// `diffable` (e.g. the SwiftUI `.task` in `LibraryView` calls it right
    /// after the crawl finishes, while the grid is still gated out of the
    /// view hierarchy behind `env.crawl.isComplete` and this controller's
    /// view has therefore never loaded). `applySnapshot()` cannot build
    /// anything useful without `diffable`, so it records that a snapshot is
    /// owed and returns; `viewDidLoad()` clears the flag by applying one
    /// itself once the data source exists, which picks up whatever the
    /// underlying `dataSource`/`cache` state is by then rather than replaying
    /// a stale snapshot captured at the deferred call site.
    private var pendingSnapshotNeeded = false

    /// Invoked with the asset behind a newly selected cell, or `nil` on
    /// deselect. Left as an injectable closure (rather than a hard
    /// dependency on a detail view type) so this controller stays
    /// AppKit/grid-only; the caller (the app's library screen) is
    /// responsible for what selecting a photo actually opens.
    var onSelect: ((Asset?) -> Void)?

    /// A single fixed section. The grid does not (yet) group by day/month,
    /// so there is exactly one section for the whole space.
    private static let section = 0

    init(dataSource: WindowedDataSource, cache: ThumbnailCache) {
        self.dataSource = dataSource
        self.cache = cache
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not used")
    }

    override func loadView() {
        let scroll = NSScrollView()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 160, height: 160)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        collectionView.register(PhotoCellView.self, forItemWithIdentifier: PhotoCellView.reuseIdentifier)
        collectionView.setAccessibilityIdentifier("grid.collection")
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        self.view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        diffable = NSCollectionViewDiffableDataSource<Int, AssetItemID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            let item = collectionView.makeItem(withIdentifier: PhotoCellView.reuseIdentifier, for: indexPath)
            guard let cell = item as? PhotoCellView, let self else { return item }
            if let asset = self.dataSource.item(at: indexPath.item) {
                cell.configure(asset: asset, space: itemID.space, cache: self.cache)
            }
            return cell
        }
        // A caller may have asked for a snapshot before this view ever
        // loaded (see `pendingSnapshotNeeded`). `diffable` now exists, so
        // catch up immediately on whatever the data source currently holds
        // rather than leaving the grid empty until the next prefetch or
        // space-toggle triggers another `applySnapshot()` call.
        if pendingSnapshotNeeded {
            pendingSnapshotNeeded = false
            Task { await applySnapshot() }
        }
    }

    /// Rebuilds the snapshot from `dataSource.totalCount` rows, one item
    /// identifier per index the space is expected to have.
    ///
    /// This intentionally still renders whatever rows exist while
    /// `dataSource.isReady` is false: the initial crawl can take a long time
    /// on a large library, and blocking the grid entirely until it finishes
    /// would make the app unusable during that window. What must NEVER
    /// happen is presenting that partial state as if it were the finished
    /// library. `snapshotIsComplete` (set below from the same `isReady` read)
    /// is the explicit, count-independent signal callers use to show the
    /// "Importing N of M" banner: `snapshotItemCount()` alone climbing
    /// toward some number is not evidence of completeness, only
    /// `dataSource.isReady`/`CrawlProgress.complete` is. This method reads
    /// `isReady` on every call specifically so a stale read from an earlier
    /// snapshot can never linger after the barrier flips.
    ///
    /// Item identity for a not-yet-loaded index is still well-defined:
    /// `AssetItemID` only needs `space` and a stable per-row `serverId`, and
    /// since the real server id is not known until the row loads, a
    /// negative placeholder id derived from the index is used instead. This
    /// keeps the item count (and therefore scrollbar geometry) correct as
    /// soon as `totalCount` is known, without waiting for every page to
    /// load first. When a row's real asset loads, its identifier changes
    /// from the negative placeholder to the real `(space, serverId)` pair;
    /// the diffable data source treats that as a normal identity change
    /// (remove the placeholder item, insert the real one at the same
    /// position) and calls the item provider for it, which is exactly the
    /// "this row now has data, ask the cell to configure" signal this
    /// method needs, with no separate reconfigure step. Until a row loads,
    /// its cell renders an empty placeholder background (`PhotoCellView`
    /// shows nothing when `dataSource.item(at:)` returns `nil`).
    ///
    /// `animatingDifferences: false` is deliberate: an animated diff over a
    /// 100k-item collection is expensive and pointless here, the resident
    /// set only ever grows or the space changes wholesale, neither of which
    /// benefits from a cross-fade.
    func applySnapshot() async {
        // `diffable` only exists once this controller's view has actually
        // loaded (`viewDidLoad()` builds it). `LibraryView`'s `.task` calls
        // `applySnapshot()` unconditionally right after the crawl finishes,
        // but the grid itself is gated behind `env.crawl.isComplete` in
        // `RootView`/`LibraryView`, so on first login this call can land
        // before SwiftUI has ever put `PhotoGridView` (and therefore this
        // controller's view) into the hierarchy. Rather than force-unwrap
        // and crash, no-op safely and remember that a snapshot is owed;
        // `viewDidLoad()` applies one as soon as `diffable` is ready.
        guard let diffable else {
            pendingSnapshotNeeded = true
            return
        }
        // Captured up front (not derived from the row count below) so the
        // "is this presentation of the grid the complete library" question
        // always has one answer, driven only by the crawl barrier. This is
        // read fresh on every call: a snapshot applied while mid-crawl and
        // then never refreshed after the barrier flips would otherwise keep
        // reporting stale readiness forever.
        snapshotIsComplete = dataSource.isReady
        var snapshot = NSDiffableDataSourceSnapshot<Int, AssetItemID>()
        snapshot.appendSections([Self.section])
        var identifiers: [AssetItemID] = []
        identifiers.reserveCapacity(dataSource.totalCount)
        for index in 0..<dataSource.totalCount {
            if let asset = dataSource.item(at: index) {
                identifiers.append(AssetItemID(space: asset.space, serverId: asset.id))
            } else {
                identifiers.append(AssetItemID(space: dataSource.space, serverId: -Int64(index) - 1))
            }
        }
        snapshot.appendItems(identifiers, toSection: Self.section)
        diffable.apply(snapshot, animatingDifferences: false)
    }

    /// Whether the most recently applied snapshot reflects a fully-crawled
    /// library, per `dataSource.isReady` at the time `applySnapshot()` last
    /// ran. `snapshotItemCount()` climbing to match `dataSource.totalCount`
    /// is NOT sufficient evidence of this: a mid-crawl `totalCount` grows
    /// too, so `snapshotItemCount() == totalCount` can be true while this is
    /// still false. Callers deciding whether to present the grid as "the
    /// full library" must check this, not the item count.
    private(set) var snapshotIsComplete: Bool = false

    func snapshotItemCount() -> Int {
        diffable?.snapshot().numberOfItems ?? 0
    }

    /// `NSCollectionViewPrefetching`: as the collection view reports index
    /// paths it expects to need soon, load the page(s) covering the lowest
    /// requested index. `WindowedDataSource` internally dedupes repeat
    /// requests for a page already loaded or in flight, so an aggressive
    /// prefetch here does not cause redundant network calls.
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let minIndex = indexPaths.map(\.item).min() else { return }
        let offset = (minIndex / dataSource.pageSize) * dataSource.pageSize
        Task {
            await dataSource.loadWindow(offset: offset, limit: dataSource.pageSize)
            await applySnapshot()
        }
    }

    /// `NSCollectionViewDelegate`: reports the asset behind the first newly
    /// selected index path to `onSelect`. A row that has not loaded yet
    /// (`dataSource.item(at:)` returns `nil`, e.g. a placeholder identifier
    /// from a still-in-flight page) reports nothing rather than opening
    /// detail on incomplete data; the selection itself is still recorded by
    /// the collection view, so the cell shows as selected either way.
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        onSelect?(dataSource.item(at: indexPath.item))
    }

    /// `NSCollectionViewDelegate`: clears the detail view when the grid's
    /// selection is cleared (e.g. the user dismisses the sheet, which
    /// deselects the underlying cell).
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        if collectionView.selectionIndexPaths.isEmpty {
            onSelect?(nil)
        }
    }
}
