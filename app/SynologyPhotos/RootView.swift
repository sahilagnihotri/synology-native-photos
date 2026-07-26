import SwiftUI
import PhotosCore

/// The two screens the app can be showing at any one time. Purely a
/// function of `AuthPhase`: every phase other than `.valid` renders the
/// login screen, since none of the others (loggedOut, authenticating,
/// needsOtp, restoring, expired, invalid) leave the app with a session it
/// can make authenticated calls with.
enum RootRoute: Equatable { case login, library }

/// Pure mapping from `AuthPhase` to `RootRoute`, kept as a standalone type so
/// the launch/sign-out routing decision is testable without instantiating
/// any SwiftUI view or the real `PhotosCore`.
struct RootRouter {
    static func route(for phase: AuthPhase) -> RootRoute {
        if case .valid = phase { return .library }
        return .login
    }
}

/// Pure debounce gate for the activation auto-sync, kept out of the SwiftUI
/// view so the "do not reconcile on every trivial focus change" rule is
/// unit-testable without a scene. A sync is allowed when none has run yet, or
/// once at least `minimumInterval` seconds have passed since the last one.
enum AutoSyncGate {
    /// Minimum gap between automatic syncs (activation and periodic). Chosen
    /// so quickly clicking away and back (Cmd-Tab, a notification, a Spotlight
    /// peek), or a periodic tick landing right after a manual Refresh, does
    /// not fire a second reconcile back to back.
    static let minimumInterval: TimeInterval = 20

    /// How often the periodic background sync ticks while the library grid is
    /// active. A light every-few-minutes cadence: often enough that changes
    /// made elsewhere trickle in on their own, rare enough to be negligible
    /// load. The `minimumInterval` debounce still coalesces a tick that would
    /// otherwise land just after another sync.
    static let periodicInterval: TimeInterval = 150

    static func shouldSync(lastSyncAt: Date?, now: Date, minimumInterval: TimeInterval = minimumInterval) -> Bool {
        guard let lastSyncAt else { return true }
        return now.timeIntervalSince(lastSyncAt) >= minimumInterval
    }
}

/// Owns the app's long-lived objects for one run: the core bridge, the auth
/// state machine, the windowed grid data source, the two-tier thumbnail
/// cache, the QuickLook temp-file cache, crawl progress, and the
/// Personal/Shared selection. Built with a `PhotosCoreProtocol` so tests use
/// `FakePhotosCore`; production passes the real `PhotosCore` (conforms via
/// the extension in `PhotosCoreProtocol.swift`).
@MainActor
@Observable
final class AppEnvironment {
    let client: PhotosCoreClient
    /// The raw core bridge, kept alongside the serializing `PhotosCoreClient`
    /// actor above because `LoginView`'s certificate-approval flow
    /// (`CertApprovalViewModel`) needs `fetchCertificate` before any
    /// session exists, i.e. before there is anything else for the actor to
    /// serialize against; sharing this reference is simpler than adding a
    /// pass-through on `PhotosCoreClient` for a single pre-auth call.
    let coreClient: PhotosCoreProtocol
    let auth: AuthStateMachine
    let dataSource: WindowedDataSource
    let thumbnailCache: ThumbnailCache
    let tempCache: TempFileCache
    /// Two-tier cache of full downloaded originals (RAM decode + on-disk
    /// bytes), feeding the detail viewer's photo and video load paths so a
    /// re-open is instant and never re-downloads. Sized from the persisted
    /// cache Settings.
    let originalCache: OriginalImageCache
    let crawl: CrawlProgressModel
    let spaceSelection: SpaceSelection
    let discoveryCoverCache: DiscoveryCoverCache
    let searchFilters: SearchFilterModel
    /// The library grid's Quick Filter selection (file type, date taken,
    /// rating). Local-only, so unlike `searchFilters` it needs no client.
    let quickFilter: QuickFilterModel
    let host: String
    let accountCacheDir: URL

    init(core: PhotosCoreProtocol, accountCacheDir: URL, host: String) {
        let c = PhotosCoreClient(core: core)
        self.client = c
        self.coreClient = core
        self.auth = AuthStateMachine(client: core)
        self.dataSource = WindowedDataSource(client: c, space: .personal, pageSize: 200)
        self.thumbnailCache = ThumbnailCache(client: c)
        self.tempCache = TempFileCache(limit: 24)
        let cacheSettings = CacheSettingsStore()
        self.originalCache = OriginalImageCache(
            cacheDir: accountCacheDir.appendingPathComponent("originals", isDirectory: true),
            ramLimitBytes: cacheSettings.ramLimitBytes,
            diskLimitBytes: cacheSettings.diskLimitBytes)
        self.crawl = CrawlProgressModel(client: c)
        self.spaceSelection = SpaceSelection(current: .personal)
        self.discoveryCoverCache = DiscoveryCoverCache(client: c)
        self.searchFilters = SearchFilterModel(client: c)
        self.quickFilter = QuickFilterModel()
        self.host = host
        self.accountCacheDir = accountCacheDir
    }
}

/// Top-level switch between the login screen and the library, driven
/// entirely by `env.auth.phase` through `RootRouter`. Neither branch owns
/// any state of its own beyond what `AppEnvironment` already holds, so a
/// route change never loses in-flight work outside the screen it leaves.
struct RootView: View {
    @State var env: AppEnvironment

    var body: some View {
        switch RootRouter.route(for: env.auth.phase) {
        case .login: LoginView(auth: env.auth, client: env.coreClient)
        case .library: LibraryView(env: env)
        }
    }
}

/// The four things the completed-or-not library area can show at any one
/// time. Purely a function of the crawl barrier plus the current item count
/// plus any recorded crawl failure, kept as a standalone type (mirroring
/// `RootRouter` above) so the decision is testable without a live
/// `AppEnvironment` or any AppKit view.
enum LibraryContentRoute: Equatable {
    case importing
    case empty
    case grid
    case failed(message: String)
}

extension LibraryContentRoute {
    /// `isComplete` must come only from `CrawlProgress.complete` (the
    /// barrier `CrawlProgressModel` mirrors); this never treats a nonzero
    /// count as evidence of completeness on its own, since a mid-crawl
    /// count also grows. Once complete, an empty library and a nonempty one
    /// are distinguished purely by `itemCount`, so the importing spinner
    /// never lingers after the barrier flips.
    ///
    /// `failure` takes precedence over the importing spinner while
    /// incomplete: a crawl that has thrown is no longer "in progress" even
    /// though the barrier never got to flip, so it must not look identical
    /// to a healthy crawl still in flight. It has no bearing once `isComplete`
    /// is true, since a completed crawl already has an authoritative answer.
    static func route(isComplete: Bool, itemCount: Int, failure: String? = nil) -> LibraryContentRoute {
        guard isComplete else {
            if let failure { return .failed(message: failure) }
            return .importing
        }
        return itemCount > 0 ? .grid : .empty
    }
}

/// Library scene: sidebar + content split, importing progress + grid +
/// detail.
///
/// Identifiable wrapper so the photo editor can be presented with
/// `.sheet(item:)`. `Asset` itself is not `Identifiable` (the generated
/// binding only derives Equatable/Hashable), and its `id` is stable and unique
/// per asset, which is exactly what `.sheet(item:)` needs.
private struct EditorTarget: Identifiable {
    let asset: Asset
    var id: Int64 { asset.id }
}

/// Grid item selection opens `DetailViewerHost` in a sheet: `detailIndex`
/// is populated from `PhotoGridController.onOpenDetail`, which the
/// controller invokes with the relevant absolute grid index on a
/// deliberate open gesture (double-click or Return), not on a plain
/// selection change (nil clears the sheet on close). This is the wiring
/// `DetailQuickLookView`'s own task (51) explicitly deferred to here, since
/// extended with Return/Space keyboard opens and Left/Right paging.
///
/// The top segmented Personal/Shared toggle is replaced by a Photos-style
/// sidebar (`SidebarView`): the sidebar's "Library" row plus per-space rows
/// drive the same `SpaceSelection`/`WindowedDataSource` wiring the old
/// toggle used, so switching spaces still re-queries and re-crawls exactly
/// as before, only the control that triggers it has moved.
struct LibraryView: View {
    let env: AppEnvironment
    /// Drives the automatic syncs: transitioning to `.active` reconciles the
    /// current space, and the periodic timer only runs while `.active` (see
    /// `autoSyncTick` and `isPeriodicSyncActive`).
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: PhotoGridController
    @State private var detailIndex: Int?
    /// The photo currently open in the non-destructive editor sheet, or `nil`
    /// when the editor is closed. Set from the detail viewer's Edit button.
    @State private var editorTarget: EditorTarget?
    /// When the last space reconcile ran (manual Refresh, activation auto-sync,
    /// or the periodic timer), so `AutoSyncGate` can debounce the automatic
    /// paths against each other and against a manual Refresh. Nil until the
    /// first one runs.
    @State private var lastAutoSyncAt: Date?
    /// True while a reconcile + grid reload is in flight, so the automatic
    /// paths never stack a second one on top of a running sync. Checked and
    /// set synchronously in `syncLibrary`.
    @State private var isSyncing = false
    @State private var sidebarSelection: SidebarItem? = .library
    @State private var zoom = GridZoomModel()
    @State private var deleteController: DeleteController
    /// Backs the Recently Deleted (recycle bin) view. Long-lived alongside the
    /// grid controller so its loaded contents and selection survive navigating
    /// away and back within one library session.
    @State private var recentlyDeletedModel: RecentlyDeletedModel
    /// The tile-grid model for whichever discovery kind is currently
    /// selected, or `nil` when the sidebar is not on a discovery-tiles
    /// section. Rebuilt (not cached across sections) every time the section
    /// changes: discovery collections have no local index, so there is
    /// nothing stale to protect by keeping the old model around, and a
    /// fresh model means a fresh `.load()` reflects the NAS's current state
    /// every time the user revisits a section.
    @State private var tilesModel: DiscoveryTilesModel?
    /// Set when a tile has been drilled into (or Favorites selected
    /// directly): overrides `sidebarSelection`'s own routing for the
    /// content area so the photo grid can show one specific person/place/
    /// tag/favorites collection, which `SidebarItem` alone has no room to
    /// carry (a sidebar row is a fixed kind, not a specific id). Cleared by
    /// every `onChange(of: sidebarSelection)` transition except the one that
    /// set it, so navigating to a different sidebar row (including
    /// re-entering the same tiles section) always drops back out of a
    /// drilled-in collection first.
    @State private var drilledInCollection: DiscoveryCollection?
    /// The toolbar search field's live text, bound directly to `.searchable`.
    /// Read-only search: there is no saved-search list, and clearing this
    /// back to empty simply returns to whatever the sidebar was already
    /// routed to, per the brief.
    @State private var searchQuery = ""
    /// The query actually searched for after debounce, or `nil` when no
    /// search is active. Kept separate from `searchQuery` so keystrokes
    /// never fire a request on every character; `searchTask` below commits
    /// this once the user pauses typing.
    @State private var activeSearch: String?
    @State private var searchTask: Task<Void, Never>?
    /// The Quick Filter currently applied to the library grid, or `nil` when
    /// none is active. Set by Apply in the filter popover; when non-nil the
    /// content area shows the filtered (flat) grid, overlaying the plain
    /// library exactly the way `activeSearch` overlays it for search. Mutually
    /// exclusive with `activeSearch` (the filter button is hidden during a
    /// search) and cleared whenever the sidebar selection changes or a search
    /// starts, so it only ever applies to the library grid it was set from.
    @State private var activeFilter: FilterQuery?

    init(env: AppEnvironment) {
        self.env = env
        let c = PhotoGridController(dataSource: env.dataSource, cache: env.thumbnailCache, client: env.client)
        _controller = State(initialValue: c)
        _deleteController = State(initialValue: DeleteController(client: env.client))
        _recentlyDeletedModel = State(initialValue: RecentlyDeletedModel(client: env.client))
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } detail: {
            // The detail viewer renders INLINE in the split view's detail
            // column (not in a `.sheet`), so it fills the pane with the
            // sidebar still visible instead of collapsing to a small centered
            // modal. The grid (`content`) stays mounted underneath the whole
            // time, so returning from a photo is instant with no re-query.
            ZStack {
                content
                if detailIndex != nil {
                    detailViewer
                        .transition(.opacity)
                }
            }
        }
        .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search Photos")
        .task {
            wireGridCallbacks()
            await env.crawl.startCrawl(space: env.spaceSelection.current)
            await env.dataSource.refreshCount()
            await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
            await controller.applySnapshot()
        }
        .onChange(of: sidebarSelection) { _, newValue in
            guard let newValue else { return }
            drilledInCollection = nil
            // A Quick Filter only ever applies to the library grid it was set
            // from; leaving that grid (to another space, discovery, or the
            // recycle bin) drops it so it never lingers over an unrelated view.
            activeFilter = nil
            switch newValue.route(currentSpace: env.spaceSelection.current) {
            case .grid(let space):
                tilesModel = nil
                Task { await switchSpace(to: space) }
            case .discoveryTiles(let kind):
                controller.clearSelection()
                let model = DiscoveryTilesModel(client: env.client, kind: kind)
                tilesModel = model
                Task { await model.load() }
            case .discoveryGrid(let collection):
                tilesModel = nil
                Task { await switchCollection(to: collection) }
            case .recentlyDeleted:
                // The recycle bin is its own view (RecentlyDeletedView), not
                // the photo grid, and loads itself on appear. Clear the grid
                // selection so a stale library selection cannot linger under
                // it, but there is no windowed data source to switch here.
                tilesModel = nil
                controller.clearSelection()
            case .map:
                // The Map is its own full view (MapDestinationView), not the
                // photo grid, and loads its located assets itself on appear.
                // Same as the recycle bin: clear the grid selection, but there
                // is no windowed data source to switch or crawl to start.
                tilesModel = nil
                controller.clearSelection()
            }
        }
        .onChange(of: drilledInCollection) { _, newValue in
            guard let newValue else { return }
            Task { await switchCollection(to: newValue) }
        }
        .onChange(of: searchQuery) { _, newValue in
            searchTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                // Empty query: drop straight back to whatever the sidebar is
                // already routed to, no debounce needed for clearing. Only
                // do this if a search was actually active, so clearing an
                // already-empty field on first launch is a no-op rather
                // than an extra reload. Also clears any date filter that was
                // active for the search being abandoned, per the brief
                // ("clearing filters + keyword returns to the current
                // sidebar view") -- a filter left over from a previous
                // search should not silently apply to whatever comes next.
                guard activeSearch != nil else { return }
                activeSearch = nil
                env.searchFilters.clear()
                Task { await restoreCurrentRoute() }
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await runSearch(trimmed)
            }
        }
        .onChange(of: detailIndex) { _, newValue in
            // When the viewer closes, hand keyboard focus back to the grid so
            // arrow keys, Space, and Cmd+Down keep working without a click.
            // The inline viewer's KeyCatcher grabbed first responder while it
            // was up; nothing else reclaims it on the same window otherwise.
            if newValue == nil { restoreGridFocus() }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // Only on a real transition INTO active (not an active->active
            // report), so re-focusing the window auto-syncs while ordinary
            // in-app changes do not. The debounce and route/crawl guards live
            // in `autoSyncTick`.
            guard newPhase == .active, oldPhase != .active else { return }
            Task { await autoSyncTick() }
        }
        // Light periodic background sync: while the app is active AND the
        // space-backed library grid is on screen, reconcile + reload on a
        // timer so changes made elsewhere trickle in without a manual
        // Refresh. `.task(id:)` ties the loop's lifetime to
        // `isPeriodicSyncActive`: it starts when that becomes true, is
        // cancelled the moment it flips false (app deactivated, or the user
        // navigates to discovery/search/recently-deleted), and is torn down
        // with the view on sign-out. Each tick still runs through
        // `autoSyncTick`, so it shares the same debounce/in-flight/route
        // guards as the manual and on-activation paths.
        .task(id: isPeriodicSyncActive) {
            guard isPeriodicSyncActive else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(AutoSyncGate.periodicInterval))
                if Task.isCancelled { break }
                await autoSyncTick()
            }
        }
        // The everyday delete confirm, shared verbatim by the grid and the
        // full-photo detail viewer. The space is read from the data source
        // (the current library/collection/search source). On a confirmed
        // success it closes the detail viewer if it happens to be open (a
        // no-op for a grid delete, where `detailIndex` is already nil) and
        // refreshes the current grid so the deleted rows disappear.
        .deleteConfirm(deleteController, space: env.dataSource.space) {
            detailIndex = nil
            await refreshCurrentGrid()
        }
        // The non-destructive crop/rotate editor. Saving there uploads a NEW
        // photo (the original is never touched); on save the sheet dismisses
        // itself and this refreshes the library so the new photo shows up (it
        // may lag until the NAS finishes re-indexing).
        .sheet(item: $editorTarget) { target in
            PhotoEditorView(
                asset: target.asset,
                space: env.dataSource.space,
                client: env.client,
                cache: env.tempCache,
                onClose: { editorTarget = nil },
                onSaved: { await reconcileAndReloadGrid() })
        }
    }

    /// The inline detail viewer shown over the grid when `detailIndex` is set.
    /// Reads assets lazily through the same windowed data source the grid
    /// uses (never materializing the whole space) and writes paging back into
    /// `detailIndex` so the grid selection can stay in sync.
    @ViewBuilder
    private var detailViewer: some View {
        DetailViewerHost(
            assetCount: env.dataSource.totalCount,
            assetAt: { env.dataSource.item(at: $0) },
            space: env.dataSource.space,
            client: env.client,
            cache: env.tempCache,
            originalCache: env.originalCache,
            thumbnailCache: env.thumbnailCache,
            synoToken: currentSynoToken(),
            currentIndex: Binding(
                get: { detailIndex ?? 0 },
                set: { detailIndex = $0 }
            ),
            onClose: { detailIndex = nil },
            // Delete from full-photo view runs the SAME DeleteController flow
            // the grid uses: raise the confirm for just this asset (with its
            // filename, so Cmd-Z can undo it); the shared `.deleteConfirm`
            // modifier closes the viewer and refreshes on a confirmed success.
            onDelete: { asset in deleteController.requestDelete(ids: [asset.id], filenames: [asset.filename]) },
            // Edit opens the non-destructive crop/rotate editor for this photo.
            // Saving there uploads a NEW photo and leaves the original
            // untouched; the sheet's onSaved refreshes the library.
            onEdit: { asset in editorTarget = EditorTarget(asset: asset) }
        )
    }

    /// Returns keyboard first responder to the grid's collection view. Run on
    /// the next main-actor turn so SwiftUI has removed the viewer's own
    /// KeyCatcher first; otherwise the makeFirstResponder would race the
    /// teardown and the grid could end up with no responder at all.
    private func restoreGridFocus() {
        Task { @MainActor in
            let collectionView = controller.collectionView
            collectionView.window?.makeFirstResponder(collectionView)
        }
    }

    /// Wires the grid controller's keyboard/selection callbacks to this
    /// view's state. Extracted from `.task` so it reads as one step rather
    /// than being interleaved with the crawl/load sequence around it. All
    /// four callbacks receive an absolute grid index directly from the
    /// controller (no re-derivation from an asset needed), which is what
    /// keeps this wiring O(1) per keypress/click regardless of library
    /// size.
    private func wireGridCallbacks() {
        // Selection changes (click, arrow-key move, cleared) only track the
        // selection; they MUST NOT open the detail viewer. Apple Photos opens
        // only on a deliberate gesture: double-click or Return (onOpenDetail),
        // or Space for QuickLook (onToggleQuickLook). Wiring selection changes
        // to detailIndex is exactly the bug where arrow keys opened the image.
        controller.onSelectionChanged = { _ in }
        controller.onOpenDetail = { index in detailIndex = index }
        controller.onToggleQuickLook = { index in
            detailIndex = (detailIndex != nil) ? nil : index
        }
        controller.onClearSelection = { detailIndex = nil }
        // Delete / Cmd-Delete on the grid starts the everyday delete flow (a
        // confirm, then a real delete into the Synology recycle bin). The
        // recycle bin has its own view with its own actions and is never this
        // photo grid, so there is no in-trash special case here anymore.
        controller.onDeleteRequested = { _ in requestDeleteSelected() }
        // Cmd-Z undoes the most recent delete, restoring those photos from
        // the recycle bin. A safe no-op when there is nothing to undo.
        controller.onUndoDelete = { Task { await undoLastDelete() } }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 8) {
            HStack {
                Text(headerTitle)
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                // The crawl status line only ever applies to the space-backed
                // Library grid: discovery collections have no crawl barrier
                // at all (they are fetched live), so showing "Importing..."
                // over a tile grid, a discovery photo grid, or search
                // results would be a meaningless, permanently-stuck status.
                if activeSearch == nil, activeFilter == nil, case .grid = currentRoute, !env.crawl.isComplete {
                    Text(env.crawl.statusText).accessibilityIdentifier("crawl.status")
                }
                // The Quick Filter applies only to the space-backed library
                // grid: the facets it filters (file type, date taken, rating)
                // are local-index columns. People/Places/Tags/Favorites are
                // server-side clusters with their own sidebar destinations, so
                // they are intentionally not folded in here. Hidden while a
                // search is active, which has its own filter bar.
                if activeSearch == nil, isLibraryGridRoute {
                    QuickFilterBarView(model: env.quickFilter, client: env.client, onApply: {
                        Task { await applyQuickFilter() }
                    }, onClear: {
                        Task { await clearQuickFilter() }
                    })
                }
                // Filters only make sense once a keyword search is active:
                // the NAS has no way to run a date-only search (see
                // `runSearch`'s doc comment), so the filter button only
                // appears alongside actual search results, matching Photos'
                // own placement of its filter control next to active search.
                if activeSearch != nil {
                    SearchFilterBarView(model: env.searchFilters) {
                        Task { await runSearch(activeSearch ?? searchQuery) }
                    }
                }
                if isShowingPhotoGrid {
                    if controller.selection.count > 0 {
                        Text("\(controller.selection.count) selected")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("selection.count")
                        // The everyday delete: a real delete into the Synology
                        // recycle bin, recoverable from Recently Deleted.
                        Button(role: .destructive) { requestDeleteSelected() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityIdentifier("grid.delete")
                    }
                    // Refresh re-runs a delta reconcile for the current space
                    // so NAS-side changes made elsewhere (and this app's own
                    // deletes) show up. Only meaningful for the space-backed
                    // library grid: discovery collections and search are
                    // fetched live on every load and have no crawl to reconcile.
                    if isLibraryGridRoute {
                        Button { Task { await syncLibrary() } } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("library.refresh")
                    }
                    ZoomSliderView(zoom: zoom) { size in
                        controller.applyZoom(itemSize: size)
                    }
                }
                Button("Sign Out") {
                    Task {
                        let so = SignOutController(
                            client: env.client, auth: env.auth,
                            keychainHost: env.host,
                            keychainUsername: currentUsername(),
                            accountCacheDir: env.accountCacheDir,
                            thumbnailCache: env.thumbnailCache,
                            clearTempCache: {
                                await env.tempCache.clearAll()
                                await env.originalCache.clear()
                            })
                        await so.signOut()
                    }
                }
                .accessibilityIdentifier("session.signout")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            // The photo grid lives at exactly ONE structural position (the
            // `.grid` case here), shared by the plain (date-sectioned) library,
            // search results, Quick Filter results, and a discovery drill-in.
            // Those states differ only in the data source (already switched by
            // setSpace/setSearch/setFilter/setCollection) and the header, so
            // resolving them to the same `.grid` case keeps SwiftUI from moving
            // the grid's NSViewController between branches when a search or
            // filter toggles: the previous per-state branches re-hosted that
            // shared controller and left the grid showing stale rows. The
            // transient states (importing/empty/failed) render in the grid's
            // place, and the genuinely different views (discovery tiles, the
            // recycle bin) replace it on their own routes.
            switch libraryDisplay {
            case .grid:
                PhotoGridView(controller: controller)
            case .importing(let label, let accessibilityId):
                ProgressView(label).accessibilityIdentifier(accessibilityId)
            case .empty(let state):
                emptyStateView(state)
            case .failed(let message, let retry):
                CrawlFailedView(message: message, onRetry: retry)
            case .discoveryTiles:
                if let tilesModel {
                    DiscoveryTileGridView(model: tilesModel, cache: env.discoveryCoverCache) { collection in
                        drilledInCollection = collection
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .recentlyDeleted:
                // The recycle bin has its own view (not the photo grid): it
                // reads `RecycleItem`s live from the NAS, loads itself on
                // appear, and owns its own Restore / Delete Permanently action
                // bar. A restore asks the library to refresh so the returned
                // items reappear.
                RecentlyDeletedView(model: recentlyDeletedModel, client: env.client) {
                    await reconcileAndReloadGrid()
                }
            case .map:
                // The Map is its own full view: it plots located photos, loads
                // itself on appear (and on space change), and opens the photos
                // behind a tapped cluster/pin in the app's detail stack. Like
                // the recycle bin it is not the photo grid and has no crawl.
                MapDestinationView(
                    client: env.client,
                    space: env.spaceSelection.current,
                    thumbnailCache: env.thumbnailCache,
                    tempCache: env.tempCache,
                    originalCache: env.originalCache,
                    synoToken: currentSynoToken())
            }
        }
    }

    /// The single thing the content area shows at any moment. Search, the Quick
    /// Filter, the plain library, and a discovery drill-in all resolve to
    /// `.grid` so the photo grid can be hosted at one stable position in the
    /// view tree (see `content`'s `switch`); the transient and alternate states
    /// carry whatever the view in the grid's place needs (a spinner label, the
    /// empty-state kind, the failed message plus its retry). Computed fresh on
    /// every body evaluation off the observable data source / crawl, so a
    /// source or readiness change flips it without any stale routing lingering.
    private enum LibraryDisplay {
        case grid
        case importing(label: String, accessibilityId: String)
        case empty(LibraryEmptyState)
        case failed(message: String, retry: () async -> Void)
        case discoveryTiles
        case recentlyDeleted
        case map
    }

    /// Which empty state the content area shows when a grid-backed route has no
    /// rows: the plain library, a keyword search, the Quick Filter, or a
    /// discovery collection. Each carries only what its view needs to render.
    private enum LibraryEmptyState {
        case library(Space)
        case search(query: String)
        case filter(summary: String)
        case discovery(title: String)
    }

    /// Collapses the whole content-area routing into one `LibraryDisplay` so the
    /// grid slot in `content` is invariant across a search/filter toggle. Reads
    /// the same crawl-barrier-vs-count decision (`LibraryContentRoute.route`)
    /// each grid-backed route already used; an active search or filter overlays
    /// the plain library exactly as before.
    private var libraryDisplay: LibraryDisplay {
        if let activeSearch {
            switch LibraryContentRoute.route(
                isComplete: env.dataSource.isReady, itemCount: env.dataSource.totalCount) {
            case .importing: return .importing(label: "Searching...", accessibilityId: "search.progressview")
            case .empty: return .empty(.search(query: activeSearch))
            case .grid: return .grid
            case .failed(let message): return .failed(message: message, retry: { await runSearch(activeSearch) })
            }
        }
        if let activeFilter {
            // A Quick Filter overlays the plain library the same way an active
            // search does. On the LOCAL route (file type / date / rating) the
            // count is exact so `isReady` is true immediately, resolving
            // straight to `.grid` (nonzero) or `.empty` (no match). On the
            // SERVER route (People/Geolocation) readiness is estimated from
            // short pages like search, so a full first page briefly shows the
            // "Filtering..." spinner until the last page arrives, exactly as an
            // active search does.
            switch LibraryContentRoute.route(
                isComplete: env.dataSource.isReady, itemCount: env.dataSource.totalCount) {
            case .importing: return .importing(label: "Filtering...", accessibilityId: "quickfilter.progressview")
            case .empty: return .empty(.filter(summary: activeFilter.summary))
            case .grid: return .grid
            case .failed(let message): return .failed(message: message, retry: { await applyQuickFilter() })
            }
        }
        switch currentRoute {
        case .grid:
            switch LibraryContentRoute.route(
                isComplete: env.crawl.isComplete,
                itemCount: env.dataSource.totalCount,
                failure: env.crawl.failure) {
            case .importing: return .importing(label: env.crawl.statusText, accessibilityId: "crawl.progressview")
            case .empty: return .empty(.library(env.spaceSelection.current))
            case .grid: return .grid
            case .failed(let message):
                return .failed(message: message, retry: {
                    await env.crawl.startCrawl(space: env.spaceSelection.current)
                    await env.dataSource.refreshCount()
                    await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
                    await controller.applySnapshot()
                })
            }
        case .discoveryTiles:
            return .discoveryTiles
        case .discoveryGrid:
            switch LibraryContentRoute.route(
                isComplete: env.dataSource.isReady, itemCount: env.dataSource.totalCount) {
            case .importing: return .importing(label: "Loading...", accessibilityId: "discoverygrid.progressview")
            case .empty: return .empty(.discovery(title: headerTitle))
            case .grid: return .grid
            case .failed(let message):
                return .failed(message: message, retry: {
                    if case .discoveryGrid(let collection) = currentRoute {
                        await switchCollection(to: collection)
                    }
                })
            }
        case .recentlyDeleted:
            return .recentlyDeleted
        case .map:
            return .map
        }
    }

    /// Renders the empty state for a grid-backed route with no rows. Split out
    /// of `content` so the single grid slot's `switch` stays flat and readable.
    @ViewBuilder
    private func emptyStateView(_ state: LibraryEmptyState) -> some View {
        switch state {
        case .library(let space): EmptyLibraryView(space: space)
        case .search(let query): SearchEmptyView(query: query)
        case .filter(let summary): FilterEmptyView(summary: summary)
        case .discovery(let title): DiscoveryGridEmptyView(title: title)
        }
    }

    /// Title shown above the grid, matching Photos' own content-area
    /// heading (e.g. "Library", "Personal", "Shared", "Favorites"). An
    /// active search shows the query itself, matching Photos' own titling
    /// of a search results page; a drilled-in tile (People/Places/Tags)
    /// shows the tile's own name instead of the section's generic title,
    /// e.g. "Sahil" rather than "People", matching how Photos itself titles
    /// a person's page.
    private var headerTitle: String {
        if let activeSearch { return "Search: \(activeSearch)" }
        if let activeFilter {
            return activeFilter.summary.isEmpty ? "Filtered" : "Filtered: \(activeFilter.summary)"
        }
        if let drilledInCollection, drilledInCollection != .favorites,
           let tile = tilesModel?.tiles.first(where: { $0.collection == drilledInCollection }) {
            return tile.displayName.isEmpty ? currentSpaceRoute.title : tile.displayName
        }
        return currentSpaceRoute.title
    }

    /// Title shown above the grid, matching Photos' own content-area
    /// heading (e.g. "Library", "Personal", "Shared").
    private var currentSpaceRoute: SidebarItem {
        sidebarSelection ?? .library
    }

    /// The route the content area actually renders: a drilled-in tile
    /// (or Favorites) takes precedence over the sidebar's own tiles route,
    /// since `SidebarItem` has no room to carry a specific person/place/tag
    /// id. `drilledInCollection` is cleared on every sidebar change (see the
    /// `onChange(of: sidebarSelection)` handler above), so it only ever
    /// overrides the route for the section it was set from.
    private var currentRoute: SidebarSelectionRoute {
        if let drilledInCollection { return .discoveryGrid(drilledInCollection) }
        return sidebarSelection?.route(currentSpace: env.spaceSelection.current) ?? .grid(env.spaceSelection.current)
    }

    /// Whether the photo grid (Library/Shared space, a discovery
    /// collection/album drilled into, or active search results) is the
    /// thing currently on screen, as opposed to a tile grid
    /// (People/Places/Tags/Albums). Drives the selection-count/zoom-slider
    /// header controls, which only make sense against an actual photo grid.
    private var isShowingPhotoGrid: Bool {
        if activeSearch != nil { return true }
        switch currentRoute {
        case .grid, .discoveryGrid: return true
        case .discoveryTiles, .recentlyDeleted, .map: return false
        }
    }

    /// Whether the space-backed library grid is the thing on screen, gating
    /// the Refresh action (a delta reconcile only makes sense for a crawled
    /// space, not a live-fetched discovery collection or search). An active
    /// search overlays live results over whatever the sidebar is routed to,
    /// so it is never the library grid even when the sidebar row behind it is.
    private var isLibraryGridRoute: Bool {
        if activeSearch != nil { return false }
        if case .grid = currentRoute { return true }
        return false
    }

    /// Whether the periodic background sync loop should be running: only while
    /// the app is active AND the space-backed library grid is on screen. The
    /// `.task(id:)` that owns the loop keys off this, so the timer is created
    /// when it becomes true and cancelled the instant it flips false (the app
    /// deactivates, or the user leaves the library grid for discovery, search,
    /// or the recycle bin).
    private var isPeriodicSyncActive: Bool {
        scenePhase == .active && isLibraryGridRoute
    }

    /// Switches the active space (a no-op if `space` already matches
    /// `env.spaceSelection.current`) and re-runs the same
    /// crawl/refresh/load/snapshot sequence the initial `.task` runs, so a
    /// space visited for the first time gets crawled instead of showing a
    /// false empty state.
    private func switchSpace(to space: Space) async {
        // Clear any selection carried over from the previous space before
        // loading the new one: indices from a larger space are meaningless
        // (and potentially out of range) against a smaller space's grid, and
        // a stale selection would leave a highlighted row plus a keyboard
        // action targeting a row that no longer exists.
        controller.clearSelection()
        await env.spaceSelection.toggle(to: space, on: env.dataSource)
        await env.crawl.startCrawl(space: env.spaceSelection.current)
        await env.dataSource.refreshCount()
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        await controller.applySnapshot()
    }

    /// Switches the grid to windowing one discovery-browse `collection`
    /// (a person, place, tag, or favorites), the discovery-browse
    /// equivalent of `switchSpace(to:)`. Clears selection first for the same
    /// reason `switchSpace` does: indices from whatever was previously
    /// loaded (a space, or a different collection) are meaningless against
    /// the new one. There is no crawl to start (discovery collections are
    /// fetched live, not indexed), so this only resets the data source and
    /// loads its first page.
    private func switchCollection(to collection: DiscoveryCollection) async {
        controller.clearSelection()
        await env.dataSource.setCollection(collection)
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        await controller.applySnapshot()
    }

    /// Refreshes whatever grid is currently on screen after a delete: drops
    /// the cached rows, re-reads the count, reloads the first window, and
    /// re-applies the snapshot so removed rows disappear. Clears the selection
    /// because its absolute indices no longer line up once rows have shifted.
    private func refreshCurrentGrid() async {
        await env.dataSource.reload()
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        controller.clearSelection()
        await controller.applySnapshot()
    }

    /// Raw delta reconcile for the current space followed by a grid reload, so
    /// NAS-side changes made elsewhere (and this app's own deletes/restores)
    /// show up. Reuses the crawl model's reconcile entry point rather than a
    /// fresh full crawl. Stamps `lastAutoSyncAt` so every automatic path
    /// debounces against it.
    ///
    /// Ungated on purpose: the callers that must always reflect a change
    /// immediately (Cmd-Z undo, a recycle-bin restore) use this directly.
    /// `PhotosCoreClient` is an actor, so overlapping reconciles serialize
    /// rather than race, and `refreshCurrentGrid` is idempotent, so a rare
    /// overlap is wasteful at worst, never unsafe.
    private func reconcileAndReloadGrid() async {
        lastAutoSyncAt = Date()
        await env.crawl.reconcile(space: env.spaceSelection.current)
        await refreshCurrentGrid()
    }

    /// The visible Refresh action for the library, guarded against overlapping
    /// itself: if a sync is already in flight, this is a no-op so a reconcile
    /// is never double-loaded on top of another. The `isSyncing` check-and-set
    /// is synchronous (no `await` between them), so on the main actor two
    /// callers can never both pass it. Drives the manual Refresh button and,
    /// via `autoSyncTick`, both automatic syncs.
    private func syncLibrary() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        await reconcileAndReloadGrid()
    }

    /// The gated automatic sync shared by the on-activation trigger and the
    /// periodic timer: only for the space-backed library grid, only once the
    /// initial crawl is done (reconciling mid-import would fight the crawl),
    /// and only when the debounce window has elapsed since the last sync
    /// (`AutoSyncGate`, whose clock the manual Refresh stamps too, so the two
    /// automatic paths coalesce with a manual Refresh and with each other and
    /// never run two reconciles back to back).
    private func autoSyncTick() async {
        guard isLibraryGridRoute else { return }
        guard env.crawl.isComplete else { return }
        guard AutoSyncGate.shouldSync(lastSyncAt: lastAutoSyncAt, now: Date()) else { return }
        await syncLibrary()
    }

    // MARK: - Delete actions

    /// Starts the everyday delete for the current grid selection: resolves the
    /// selected rows to assets and raises the confirm, capturing both the ids
    /// to delete and their filenames so a subsequent Cmd-Z can undo the
    /// delete via the recycle bin. A no-op on an empty resolved selection.
    /// Nothing is deleted until the user confirms.
    private func requestDeleteSelected() {
        let assets = controller.selectedAssets()
        deleteController.requestDelete(ids: assets.map(\.id), filenames: assets.map(\.filename))
    }

    /// Undoes the most recent delete (Cmd-Z), restoring those photos from the
    /// recycle bin. A no-op when there is nothing to undo. On a successful
    /// restore it runs the same reconcile + grid reload the recycle-bin
    /// Restore uses, so the returned photos reappear in the grid (a plain
    /// local reload is not enough: the restored rows only re-enter the local
    /// index once the reconcile pulls them back from the NAS).
    private func undoLastDelete() async {
        await deleteController.undoLastDelete {
            await reconcileAndReloadGrid()
        }
    }

    /// Runs a debounced keyword search: same reset/reload/snapshot sequence
    /// as `switchCollection`, since search is windowed the same way (a live
    /// NAS call, no local index or crawl barrier). Setting `activeSearch`
    /// is what actually switches the content area over to showing results;
    /// this always happens after the data source itself is already
    /// windowing the new keyword, so the grid never briefly shows the
    /// previous view's stale rows under the new header.
    ///
    /// Always applies `env.searchFilters.currentFilters` alongside the
    /// keyword: the NAS requires a non-empty `keyword` on every
    /// `Search.Search` call (confirmed against the real NAS -- an absent or
    /// empty keyword is rejected outright, so there is no way to run a
    /// date-only search), which is why the filter popover only lets Apply
    /// be pressed while a keyword is already active.
    private func runSearch(_ keyword: String) async {
        controller.clearSelection()
        // Search and the Quick Filter are mutually exclusive overlays; a
        // search takes over, so drop any active filter first.
        activeFilter = nil
        await env.dataSource.setSearch(keyword, filters: env.searchFilters.currentFilters)
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        await controller.applySnapshot()
        activeSearch = keyword
    }

    /// Applies the current Quick Filter selection to the library grid: switches
    /// the data source over to a `.filter` source for the current space and the
    /// built `FilterQuery`, loads its first window, and sets `activeFilter` so
    /// the content area shows the filtered (flat) grid. Same reset/reload/
    /// snapshot sequence as `runSearch`, so the grid never briefly shows the
    /// unfiltered library under the filtered header. An empty (all-`nil`)
    /// selection clears instead, so pressing Apply with nothing chosen returns
    /// to the plain library rather than switching to a no-op filter source.
    private func applyQuickFilter() async {
        let query = env.quickFilter.currentQuery
        guard query.isActive else {
            await clearQuickFilter()
            return
        }
        controller.clearSelection()
        // People/Geolocation are server-side Browse.Item clusters with no local
        // index, so a query that `usesServerFilter` routes to a live remote
        // window (person/geo + date only); everything else (file type, rating,
        // date) stays on the local `filterAssets` path. Both keep the grid at
        // the one stable `.grid` slot, so neither reintroduces the hosting bug.
        if query.usesServerFilter {
            await env.dataSource.setRemoteFilter(
                space: env.spaceSelection.current,
                personId: query.personId,
                geocodingId: query.geocodingId,
                startTime: query.takenAfter,
                endTime: query.takenBefore)
        } else {
            await env.dataSource.setFilter(space: env.spaceSelection.current, query: query)
        }
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        await controller.applySnapshot()
        activeFilter = query
    }

    /// Clears the Quick Filter and returns the grid to the plain, date-
    /// sectioned library for the current space. Switches the data source back
    /// to a `.space` source (which restores the date-section geometry) and
    /// reloads, mirroring how clearing a search returns to `currentRoute`. A
    /// Quick Filter is only ever active over the library grid, so restoring the
    /// current space is always the right destination.
    private func clearQuickFilter() async {
        env.quickFilter.clear()
        activeFilter = nil
        controller.clearSelection()
        await env.dataSource.setSpace(env.spaceSelection.current)
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        await controller.applySnapshot()
    }

    /// Re-windows the data source against whatever `currentRoute` points at
    /// once a search is cleared, since `runSearch` switched it over to the
    /// `.search` source and it needs to go back to the space/collection the
    /// sidebar (or a drilled-in tile) was already showing.
    private func restoreCurrentRoute() async {
        switch currentRoute {
        case .grid(let space):
            await switchSpace(to: space)
        case .discoveryGrid(let collection):
            await switchCollection(to: collection)
        case .discoveryTiles, .recentlyDeleted, .map:
            // None of a tile grid, the recycle bin, or the Map has a photo data
            // source to restore: each fetches its own contents independently.
            break
        }
    }

    /// The signed-in account username, read from the current auth phase.
    private func currentUsername() -> String {
        if case .valid(let session) = env.auth.phase { return session.username }
        return ""
    }

    /// The current session's `syno_token`, if any. Passed to
    /// `DetailViewerHost` for the (currently unreachable, see
    /// `DetailVideoPlayerView`'s file header) case where a future video
    /// playback URL needs it attached as an `X-SYNO-TOKEN` header.
    private func currentSynoToken() -> String? {
        if case .valid(let session) = env.auth.phase { return session.synoToken }
        return nil
    }
}

/// Shown in place of the importing spinner once the crawl has actually
/// thrown, rather than merely being in progress. Without this, a failed
/// crawl (auth expiry, a dropped connection, an API change) looked
/// identical to a healthy one still running: both rendered the same
/// `ProgressView` forever, which is what let a real error 119 hide in plain
/// sight for a long time. `onRetry` re-runs the same crawl the view already
/// runs on appear, so retrying is just asking the crawl to try again.
/// Shown when a discovery collection's photo grid (a person/place/tag
/// drilled into, or Favorites) genuinely has zero photos. Mirrors
/// `EmptyLibraryView`'s visual language; unlike that view there is no
/// "try the other space" hint, since there is no second discovery
/// collection to suggest.
struct DiscoveryGridEmptyView: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Photos")
                .font(.title2)
                .fontWeight(.medium)
            Text("\(title) has no photos.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("discoverygrid.empty")
    }
}

/// Shown when the Recently Deleted view has nothing in it. Mirrors
/// `DiscoveryGridEmptyView`'s visual language, worded to reassure the user
/// that an empty trash is the normal, safe state rather than an error.
struct RecentlyDeletedEmptyView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "trash")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Nothing Recently Deleted")
                .font(.title2)
                .fontWeight(.medium)
            Text("Photos you delete are moved here and can be restored before they are permanently removed.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .accessibilityIdentifier("trash.empty")
    }
}

/// Shown when an active keyword search genuinely matched nothing. Mirrors
/// `DiscoveryGridEmptyView`'s visual language, worded the way Photos itself
/// words a no-results search rather than a plain "no photos" message.
struct SearchEmptyView: View {
    let query: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Results")
                .font(.title2)
                .fontWeight(.medium)
            Text("No photos found for \u{201c}\(query)\u{201d}.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("search.empty")
    }
}

/// Shown when an active Quick Filter matched nothing in the current space.
/// Mirrors `DiscoveryGridEmptyView`/`SearchEmptyView`'s visual language, worded
/// so the user understands an empty result is the filter narrowing things down,
/// not an error, and can widen or clear it.
struct FilterEmptyView: View {
    let summary: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Matches")
                .font(.title2)
                .fontWeight(.medium)
            Text(summary.isEmpty ? "No photos match this filter." : "No photos match \(summary).")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("quickfilter.empty")
    }
}

struct CrawlFailedView: View {
    let message: String
    let onRetry: () async -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("Could Not Load Library")
                .font(.title2)
                .fontWeight(.medium)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await onRetry() } }
                .accessibilityIdentifier("crawl.tryagain")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.failed")
    }
}

