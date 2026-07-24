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
final class PhotoGridController: NSViewController, NSCollectionViewPrefetching {
    private let dataSource: WindowedDataSource
    private let cache: ThumbnailCache
    let collectionView = NSCollectionView()
    private var diffable: NSCollectionViewDiffableDataSource<Int, AssetItemID>!

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
        diffable.snapshot().numberOfItems
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
}
