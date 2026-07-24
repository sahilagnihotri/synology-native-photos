import AppKit
import PhotosCore

/// `NSCollectionView` subclass whose only job is forwarding `keyDown` to
/// `keyHandler`. The collection view (not its view controller) is the
/// actual first responder for key events once it has focus, so the
/// keyboard map lives here rather than in a `PhotoGridController` override
/// that AppKit would never call. Unrecognized keys fall through to
/// `super.keyDown(with:)` so normal responder-chain behavior (e.g. type-
/// ahead, if ever enabled) is not broken by this subclass existing.
final class KeyHandlingCollectionView: NSCollectionView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

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
    let collectionView = KeyHandlingCollectionView()
    private var diffable: NSCollectionViewDiffableDataSource<Int, AssetItemID>?
    /// Small, fixed inter-item gap, matching Photos' tight justified grid.
    /// Item size itself is variable (driven by `applyZoom`); the gap stays
    /// constant across zoom levels.
    private static let interItemGap: CGFloat = 4

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

    /// Invoked with the absolute grid index behind a newly (plain-)
    /// selected cell, or `nil` on deselect. Index rather than `Asset`
    /// directly, so the caller (the detail viewer) can page by index
    /// without a linear scan back over the data source to recover it. Left
    /// as an injectable closure (rather than a hard dependency on a detail
    /// view type) so this controller stays AppKit/grid-only; the caller
    /// (the app's library screen) is responsible for what selecting a
    /// photo actually opens.
    var onSelect: ((Int?) -> Void)?

    /// The clean, AppKit-independent selection model: click/shift/cmd/
    /// select-all transitions all flow through this, and it is what future
    /// delete/album actions (and the toolbar's selection count) read.
    /// `NSCollectionView` still owns the actual mouse hit-testing and
    /// multi-select modifier handling (it already gets that right), this
    /// controller only mirrors whatever AppKit just selected into `selection`
    /// by inspecting the modifier flags active at delegate-callback time, so
    /// there is exactly one source of truth for "what is selected" that both
    /// the grid's own highlight and the rest of the app can read.
    let selection = PhotoSelectionModel()

    /// Invoked when Return/Enter opens detail on the current single
    /// selection. Kept separate from `onSelect` because the keyboard path
    /// has no selection-changed event to hang off of, it has to be asked
    /// for explicitly.
    var onOpenDetail: ((Int) -> Void)?

    /// Invoked on Space, toggling QuickLook for the current selection. The
    /// caller owns the actual show/hide toggle state; this just reports
    /// which index Space was pressed against.
    var onToggleQuickLook: ((Int) -> Void)?

    /// Invoked on Delete/Cmd-Delete with the current selection count.
    /// Never performs a real delete itself (Phase 2, not built): the
    /// caller is expected to show the honest "coming soon" affordance.
    var onDeleteRequested: ((Int) -> Void)?

    /// Invoked on Escape when there is nothing to clear at the grid level
    /// beyond the selection itself (detail already handles its own Escape
    /// to close). Lets the caller know the grid consumed the key.
    var onClearSelection: (() -> Void)?

    /// A single fixed section. The grid does not (yet) group by day/month.
    ///
    /// TODO(date sections): rows are already sorted taken_at DESC by the
    /// core (see core/persistence/src/assets.rs), so grouping the currently
    /// loaded window into day buckets is cheap on its own. The blocker is
    /// the windowed/sparse loading model this grid relies on: an unloaded
    /// row is a placeholder identifier with no taken_at yet, so its section
    /// membership is unknown until its page loads, which would mean moving
    /// a row from an "unresolved" pseudo-section into a real date section
    /// once it loads, on top of the existing placeholder-to-real identity
    /// swap applySnapshot() already does. That is a second axis of churn on
    /// a 20k-100k item diffable snapshot, on the same code path the flicker
    /// fix just stabilized, so it did not ship in this pass. Logged here
    /// (also tracked in TODO.md) rather than faked with headers that would
    /// be wrong until every page finishes loading.
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
        layout.itemSize = NSSize(width: GridZoomModel.defaultItemSize, height: GridZoomModel.defaultItemSize)
        layout.minimumInteritemSpacing = Self.interItemGap
        layout.minimumLineSpacing = Self.interItemGap
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.prefetchDataSource = self
        collectionView.delegate = self
        collectionView.register(PhotoCellView.self, forItemWithIdentifier: PhotoCellView.reuseIdentifier)
        collectionView.setAccessibilityIdentifier("grid.collection")
        collectionView.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        scroll.documentView = collectionView
        scroll.hasVerticalScroller = true
        self.view = scroll
    }

    /// Handles one key event per the Apple Photos keyboard map (see the
    /// design spec). Returns `true` when the event was consumed (so
    /// `KeyHandlingCollectionView` does not also forward it to
    /// `super.keyDown`), `false` to let AppKit's default handling run.
    ///
    /// The "current" item for Left/Right/Up/Down/Space/Return is the
    /// selection's anchor when there is one, falling back to the first
    /// selected index, and to index 0 if nothing is selected yet (so the
    /// very first arrow-key press on a fresh grid starts navigation at the
    /// top rather than doing nothing).
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard let action = GridKeyMapper.action(for: event) else { return false }
        let count = dataSource.totalCount

        switch action {
        case .selectAll:
            selection.selectAll(count: count)
            syncSelectionHighlight()
            return true

        case .clearSelectionOrClose:
            selection.clear()
            syncSelectionHighlight()
            onClearSelection?()
            return true

        case .delete:
            onDeleteRequested?(selection.count)
            return true

        case .toggleQuickLook:
            guard let index = currentIndex() else { return true }
            onToggleQuickLook?(index)
            return true

        case .openDetail:
            guard let index = currentIndex() else { return true }
            onOpenDetail?(index)
            return true

        case .previous, .next, .up, .down:
            guard let current = currentIndex() else { return false }
            let perRow = GridNavigation.itemsPerRow(
                availableWidth: collectionView.bounds.width,
                itemSize: itemSize,
                gap: Self.interItemGap)
            guard let target = GridNavigation.target(for: action, from: current, itemsPerRow: perRow, count: count) else {
                return true
            }
            selection.click(target)
            syncSelectionHighlight()
            collectionView.scrollToItems(at: [IndexPath(item: target, section: Self.section)], scrollPosition: .nearestHorizontalEdge)
            onSelect?(target)
            return true
        }
    }

    /// The index arrow-key navigation should move from: the selection
    /// anchor if there is one, else the first selected index, else `nil`
    /// (no selection to navigate from yet; callers should let the grid's
    /// own default first-item behavior, if any, take over).
    private func currentIndex() -> Int? {
        selection.anchor ?? selection.sortedIndices.first
    }

    /// The flow layout's current square item size, read back for the
    /// itemsPerRow calculation so keyboard row navigation always matches
    /// whatever zoom level is actually on screen.
    private var itemSize: CGFloat {
        (collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.width ?? GridZoomModel.defaultItemSize
    }

    /// Applies a new square item size to the flow layout, invalidating it so
    /// the grid re-lays-out immediately (Photos-style: dragging the zoom
    /// slider resizes thumbnails live, no reload needed since identity and
    /// image content are unaffected by size).
    func applyZoom(itemSize: CGFloat) {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        let clamped = GridZoomModel.clamp(itemSize)
        guard layout.itemSize.width != clamped else { return }
        layout.itemSize = NSSize(width: clamped, height: clamped)
        layout.invalidateLayout()
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
    ///
    /// Guarded against redundant re-apply: `NSCollectionViewPrefetching`
    /// fires `prefetchItemsAt` repeatedly even while the grid is completely
    /// idle (no scrolling), and every one of those ticks used to call this
    /// method unconditionally. Re-applying an identical snapshot makes the
    /// diffable data source re-run its item provider for the visible cells,
    /// which reconfigures them for no reason, so the fix computes the
    /// proposed identifier list first and skips `diffable.apply(...)`
    /// entirely when it exactly matches what is already applied
    /// (`Self.identifiersChanged`, a pure comparison kept separate from
    /// AppKit so it is directly testable). `snapshotIsComplete` is still
    /// updated on every call regardless of that guard: the crawl barrier
    /// can flip between two calls that happen to propose the same row
    /// identifiers, and callers must see that transition without needing a
    /// row to change too.
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
        // `itemIdentifiers(inSection:)` traps if the section is not present
        // in the snapshot yet, which is exactly the state of a brand new
        // `diffable` before the very first `apply(...)` call, so that case
        // must short-circuit straight to applying rather than querying a
        // section that does not exist.
        let existingSnapshot = diffable.snapshot()
        let currentIdentifiers = existingSnapshot.sectionIdentifiers.contains(Self.section)
            ? existingSnapshot.itemIdentifiers(inSection: Self.section)
            : []
        guard Self.identifiersChanged(current: currentIdentifiers, proposed: identifiers) else {
            return
        }
        snapshot.appendItems(identifiers, toSection: Self.section)
        diffable.apply(snapshot, animatingDifferences: false)
    }

    /// Pure comparison extracted for testing: whether the row identity list
    /// `applySnapshot()` just computed actually differs from what is
    /// currently applied. Order matters (it is the grid's row order), so
    /// this is a plain element-wise comparison, not a set comparison; two
    /// snapshots with the same identifiers in a different order are, for
    /// this grid, actually different content and must still apply.
    static func identifiersChanged(current: [AssetItemID], proposed: [AssetItemID]) -> Bool {
        current != proposed
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
    /// requested index.
    ///
    /// AppKit calls this repeatedly even while the grid is sitting
    /// completely idle with no scrolling at all, not only when new index
    /// paths are actually about to come into view. `applySnapshot()`'s own
    /// no-op guard (see its doc comment) already makes a redundant call
    /// cheap and non-visual, which is the primary fix; skipping the call
    /// here when `loadWindow` returned no rows is the second half the brief
    /// asks for, avoiding even the pointless `Task` hop and identifier
    /// rebuild on the common idle tick where the page was already resident.
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let minIndex = indexPaths.map(\.item).min() else { return }
        let offset = (minIndex / dataSource.pageSize) * dataSource.pageSize
        Task {
            let rows = await dataSource.loadWindow(offset: offset, limit: dataSource.pageSize)
            guard !rows.isEmpty else { return }
            await applySnapshot()
        }
    }

    /// `NSCollectionViewDelegate`: mirrors AppKit's own hit-testing/modifier
    /// handling into `selection` (see the property's doc comment for why),
    /// then reports the index behind a plain click to `onSelect`: a plain
    /// click is the one gesture that should open detail navigation
    /// (`onSelect` drives the QuickLook sheet), shift-range and cmd-toggle
    /// only build up a multi-select for a future bulk action and must not
    /// also pop a single-item detail sheet.
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        let index = indexPath.item
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) {
            selection.shiftClick(index)
        } else if flags.contains(.command) {
            selection.toggle(index)
        } else {
            selection.click(index)
            onSelect?(index)
        }
    }

    /// `NSCollectionViewDelegate`: mirrors deselection into `selection`
    /// (a cmd-click on an already-selected cell deselects it through this
    /// path; every index AppKit reports here was selected, so removing it
    /// from `selection` is always a toggle-out) and clears the detail view
    /// once nothing at all remains selected (e.g. the user dismisses the
    /// sheet, which deselects the underlying cell).
    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        for indexPath in indexPaths where selection.isSelected(indexPath.item) {
            selection.toggle(indexPath.item)
        }
        if collectionView.selectionIndexPaths.isEmpty {
            onSelect?(nil)
        }
    }

    /// Applies `selection.selected` to the real `NSCollectionView`
    /// selection. Needed whenever `selection` changes from something other
    /// than AppKit's own mouse handling (Cmd-A, keyboard range moves): those
    /// paths mutate `selection` directly and must push the result back into
    /// AppKit so the accent-ring highlight matches.
    func syncSelectionHighlight() {
        let indexPaths = Set(selection.selected.map { IndexPath(item: $0, section: Self.section) })
        collectionView.selectionIndexPaths = indexPaths
    }
}
