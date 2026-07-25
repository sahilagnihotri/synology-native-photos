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
    /// Used only to fulfill a drag-to-Finder export promise (downloading
    /// the ORIGINAL via `downloadOriginal(unitId:)`, see
    /// `PhotoExportPromiseDelegate`). Never used for anything that would
    /// mutate NAS state; the grid's own reads all go through `dataSource`.
    private let client: PhotosCoreClient
    let collectionView = KeyHandlingCollectionView()
    /// Retains every `PhotoExportPromiseDelegate` created for the drag
    /// currently in flight (see `pasteboardWriterForItemAt:`'s doc comment
    /// on why retention is needed at all), cleared once the drag session
    /// ends.
    private var pendingExportDelegates: [PhotoExportPromiseDelegate] = []
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
    /// Invoked whenever the current selection changes (click, arrow-key
    /// move, or cleared to nil), so the caller can track what is selected
    /// (toolbar count, future bulk actions). This NEVER opens the detail
    /// viewer: in Apple Photos, moving or clicking a cell only changes the
    /// selection; opening is a separate, deliberate gesture (double-click or
    /// Return, via `onOpenDetail`). Kept as an injectable closure so this
    /// controller stays AppKit/grid-only.
    var onSelectionChanged: ((Int?) -> Void)?

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

    /// Invoked on Delete/Cmd-Delete with the current selection count. The
    /// controller performs no delete itself: the caller resolves the
    /// selection to asset ids and runs the `DeleteController` confirm flow.
    var onDeleteRequested: ((Int) -> Void)?

    /// Invoked on Cmd-Z, asking the caller to undo the most recent delete.
    /// The controller holds no undo state itself; the caller (which owns the
    /// `DeleteController` that remembers the last delete) decides whether
    /// there is anything to undo and performs the restore.
    var onUndoDelete: (() -> Void)?

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

    init(dataSource: WindowedDataSource, cache: ThumbnailCache, client: PhotosCoreClient) {
        self.dataSource = dataSource
        self.cache = cache
        self.client = client
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
        // Drag-to-Finder export (read-only): registering the file-promise
        // pasteboard type is what lets AppKit treat a drag started from
        // this collection view as a file-promise drag Finder/Desktop can
        // accept a real file drop for. The actual promise objects are
        // built per-drag in `collectionView(_:pasteboardWriterForItemAt:)`.
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
        // Double-click opens the detail viewer (Apple Photos: single click
        // selects, double-click opens). A gesture recognizer set to require
        // two clicks fires only on the second click and leaves AppKit's own
        // single-click selection handling untouched.
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)
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
        // Bounded by the collection view's own applied item count, not
        // `dataSource.totalCount` directly: the two can disagree (e.g.
        // before `applySnapshot()` has ever run, or between the data
        // source's count updating and the next snapshot apply picking it
        // up), and `scrollToItems`/`selectionIndexPaths` below crash with
        // an AppKit-level assertion if asked for an index path the
        // collection view has not actually laid out yet.
        let count = snapshotItemCount()

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

        case .undoDelete:
            onUndoDelete?()
            return true

        case .toggleQuickLook:
            guard let index = currentIndex() else { return true }
            onToggleQuickLook?(index)
            return true

        case .openDetail:
            guard let index = currentIndex() else { return true }
            onOpenDetail?(index)
            return true

        case .previous, .next, .up, .down, .extendPrevious, .extendNext, .extendUp, .extendDown:
            guard count > 0 else { return false }
            let isExtend: Bool
            switch action {
            case .extendPrevious, .extendNext, .extendUp, .extendDown: isExtend = true
            default: isExtend = false
            }
            let target: Int
            // A plain arrow always steps from the anchor (there is at most
            // one selected item on that path). A Shift+arrow must instead
            // step from the current range's far edge, the end away from the
            // anchor, e.g. after Shift+Right takes {4,5} the very next
            // Shift+Right has to step from 5, not from the anchor 4 again,
            // or every extend press would just toggle between the anchor and
            // one neighbor instead of growing the range. `farEdge()` returns
            // the anchor itself for a single-item (non-extended) selection,
            // so the very first Shift+arrow press still steps one away from
            // the anchor, matching shift-click's own first-press behavior.
            let origin = isExtend ? farEdge() : currentIndex()
            if let current = origin {
                let perRow = GridNavigation.itemsPerRow(
                    availableWidth: collectionView.bounds.width,
                    itemSize: itemSize,
                    gap: Self.interItemGap)
                guard let moved = GridNavigation.target(for: action, from: current, itemsPerRow: perRow, count: count) else {
                    return true
                }
                target = moved
            } else {
                // No selection yet: any arrow key starts navigation at the
                // first item, matching Finder/Photos (pressing an arrow key
                // with nothing selected selects item 0 regardless of
                // direction, rather than doing nothing or requiring Right
                // specifically). A Shift+arrow with nothing selected has no
                // anchor to extend from either, so it starts fresh the same
                // way a plain arrow does.
                target = 0
            }
            // Shift+arrow extends the existing range from the anchor
            // (`shiftClick`, the exact same range logic shift-click already
            // uses), a plain arrow replaces the selection with just the
            // target (`click`, which also moves the anchor). This mirrors
            // Finder/Photos: Shift+arrow keeps growing/shrinking one range
            // from a fixed anchor; a plain arrow starts a fresh single
            // selection and a fresh anchor at wherever it lands.
            if isExtend {
                selection.shiftClick(target)
            } else {
                selection.click(target)
            }
            syncSelectionHighlight()
            if target < snapshotItemCount() {
                collectionView.scrollToItems(at: [IndexPath(item: target, section: Self.section)], scrollPosition: .nearestHorizontalEdge)
            }
            // Arrow keys (plain or Shift-extended) MOVE/EXTEND the selection
            // only; they never open the detail viewer (Apple Photos: arrows
            // walk the grid, Return/double-click open). Report the change
            // through the selection-changed path, NOT onOpenDetail.
            onSelectionChanged?(target)
            return true
        }
    }

    /// The index arrow-key navigation should move from: the selection
    /// anchor if there is one, else the first selected index, else `nil`
    /// (no selection to navigate from yet, in which case `handleKey`
    /// starts fresh at index 0).
    /// Clears the current selection and its on-screen highlight. Called on a
    /// space switch so indices from the previous space cannot linger and
    /// target rows that no longer exist in the new space.
    func clearSelection() {
        selection.clear()
        syncSelectionHighlight()
    }

    /// Resolves the current selection's absolute grid indices to the server
    /// asset ids of the rows actually loaded, for a bulk action (move to
    /// Recently Deleted, restore, permanent delete). Reads through the data
    /// source's non-scheduling `residentItem(at:)`, so an index whose page
    /// has not loaded yet contributes nothing: a bulk action only ever
    /// targets rows the user can actually see, and reading the selection
    /// never triggers a wave of page loads. Sorted so the resulting id list
    /// is deterministic (matching the grid's own row order) rather than the
    /// selection set's arbitrary iteration order.
    func selectedAssetIds() -> [Int64] {
        selectedAssets().map(\.id)
    }

    /// The resident `Asset`s behind the current selection, in grid row order.
    /// Same resolution discipline as `selectedAssetIds()` (only rows already
    /// loaded, never scheduling a fetch), used by the delete flow to capture
    /// both the ids to delete and the filenames a later Cmd-Z undo matches
    /// against the recycle bin.
    func selectedAssets() -> [Asset] {
        selection.sortedIndices.compactMap { dataSource.residentItem(at: $0) }
    }

    /// Double-click opens the detail viewer on the clicked cell. Maps the
    /// click location to an index path; a click in empty space (no item)
    /// does nothing. Bounds-checked against the applied snapshot for the
    /// same reason `currentIndex()` is (a stale index must never open a
    /// blank frame).
    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        let index = indexPath.item
        guard index < snapshotItemCount() else { return }
        selection.click(index)
        syncSelectionHighlight()
        onOpenDetail?(index)
    }

    private func currentIndex() -> Int? {
        // Clamp against the applied snapshot (not dataSource.totalCount) so a
        // selection carried over from a larger space cannot open the detail
        // viewer on a stale, out-of-range row. All keyboard paths (arrow nav,
        // QuickLook, open detail) funnel through here. See GridNavigation.
        let candidate = selection.anchor ?? selection.sortedIndices.first
        return GridNavigation.clampedCurrent(candidate, count: snapshotItemCount())
    }

    /// The end of the current selection range farthest from the anchor, the
    /// index a Shift+arrow press should step from next so consecutive
    /// presses keep growing the range instead of bouncing between the
    /// anchor and its immediate neighbor.
    ///
    /// With no selection at all, behaves exactly like `currentIndex()`
    /// (falls through to `selection.anchor`, then `nil`), so a bare
    /// Shift+arrow with nothing selected still starts fresh at item 0 via
    /// `handleKey`'s own no-selection branch. With a single-item selection
    /// (no extended range yet), the far edge and the anchor are the same
    /// index, so the very first Shift+arrow press correctly steps one away
    /// from the anchor, matching a fresh shift-click's own behavior.
    private func farEdge() -> Int? {
        guard let anchor = selection.anchor else { return currentIndex() }
        let sorted = selection.sortedIndices
        guard let first = sorted.first, let last = sorted.last else { return anchor }
        // The far edge is whichever bound of the sorted range is NOT the
        // anchor's own side: if the anchor sits at or before the range's
        // start, the range extends rightward and the far edge is the max;
        // otherwise the range extends leftward and the far edge is the min.
        let candidate = anchor <= first ? last : first
        return GridNavigation.clampedCurrent(candidate, count: snapshotItemCount())
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

    /// `NSCollectionViewDelegate`: only a cell backed by an already-loaded
    /// asset can be dragged. A not-yet-loaded placeholder row (see
    /// `applySnapshot()`'s doc comment on negative placeholder ids) has no
    /// `unit_id`/`cache_key` to download from yet, so it must not start a
    /// drag that would only ever fail to fulfill.
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>) -> Bool {
        indexPaths.contains { dataSource.item(at: $0.item) != nil }
    }

    /// `NSCollectionViewDelegate`: the drag-to-Finder export itself. Builds
    /// one `NSFilePromiseProvider` per dragged cell, backed by a
    /// `PhotoExportPromiseDelegate` that fulfills by downloading the
    /// asset's ORIGINAL file on demand (never a thumbnail, never anything
    /// already cached at a lower resolution). Read-only: nothing here
    /// touches the NAS beyond that download.
    ///
    /// The delegate is retained in `pendingExportDelegates` for the
    /// duration of the drag: `NSFilePromiseProvider.delegate` is a `weak`
    /// reference (see the AppKit header), so nothing else keeps this
    /// object alive between the drag starting and Finder actually asking
    /// for the promise to be fulfilled, which can be well after this
    /// method returns.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard let asset = dataSource.item(at: indexPath.item) else { return nil }
        let delegate = PhotoExportPromiseDelegate(asset: asset, space: dataSource.space, client: client)
        pendingExportDelegates.append(delegate)
        let provider = NSFilePromiseProvider(fileType: PhotoDragExport.fileType(for: asset), delegate: delegate)
        return provider
    }

    /// `NSCollectionViewDelegate`: the drag session (successful or not) is
    /// over, so every `PhotoExportPromiseDelegate` retained for it can be
    /// released. A cancelled or failed drag still reaches this callback,
    /// so delegates are never retained forever on a drag the user abandons
    /// mid-gesture.
    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        pendingExportDelegates.removeAll()
    }

    /// `NSCollectionViewDelegate`: mirrors AppKit's own hit-testing/modifier
    /// handling into `selection` (see the property's doc comment for why),
    /// Mirrors AppKit's mouse selection into `selection` by inspecting the
    /// active modifier flags: shift extends a range, cmd toggles, a plain
    /// click replaces. A single click only SELECTS (Apple Photos does not
    /// open the viewer on a single click); opening is double-click, handled
    /// separately by `handleDoubleClick`. All three gestures report through
    /// `onSelectionChanged`, none of them opens detail.
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
        }
        onSelectionChanged?(currentIndex())
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
            onSelectionChanged?(nil)
        }
    }

    /// Applies `selection.selected` to the real `NSCollectionView`
    /// selection. Needed whenever `selection` changes from something other
    /// than AppKit's own mouse handling (Cmd-A, keyboard range moves): those
    /// paths mutate `selection` directly and must push the result back into
    /// AppKit so the accent-ring highlight matches.
    ///
    /// Filtered to indices actually within the applied snapshot's row
    /// count: `selection` is driven by `dataSource.totalCount`, which can
    /// be ahead of what the collection view has actually laid out (e.g.
    /// before the first `applySnapshot()`), and handing AppKit an index
    /// path it has no item for is an assertion crash, not a graceful no-op.
    func syncSelectionHighlight() {
        let itemCount = snapshotItemCount()
        let indexPaths = Set(selection.selected.filter { $0 < itemCount }.map { IndexPath(item: $0, section: Self.section) })
        collectionView.selectionIndexPaths = indexPaths
    }
}
