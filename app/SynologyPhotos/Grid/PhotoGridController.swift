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
