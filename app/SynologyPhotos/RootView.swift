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
    let crawl: CrawlProgressModel
    let spaceSelection: SpaceSelection
    let discoveryCoverCache: DiscoveryCoverCache
    let searchFilters: SearchFilterModel
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
        self.crawl = CrawlProgressModel(client: c)
        self.spaceSelection = SpaceSelection(current: .personal)
        self.discoveryCoverCache = DiscoveryCoverCache(client: c)
        self.searchFilters = SearchFilterModel(client: c)
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
    @State private var controller: PhotoGridController
    @State private var detailIndex: Int?
    @State private var sidebarSelection: SidebarItem? = .library
    @State private var zoom = GridZoomModel()
    @State private var deleteComingSoon = DeleteComingSoonModel()
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

    init(env: AppEnvironment) {
        self.env = env
        let c = PhotoGridController(dataSource: env.dataSource, cache: env.thumbnailCache, client: env.client)
        _controller = State(initialValue: c)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebarSelection)
        } detail: {
            content
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
        .sheet(isPresented: Binding(
            get: { detailIndex != nil },
            set: { isPresented in if !isPresented { detailIndex = nil } }
        )) {
            DetailViewerHost(
                assetCount: env.dataSource.totalCount,
                assetAt: { env.dataSource.item(at: $0) },
                space: env.dataSource.space,
                client: env.client,
                cache: env.tempCache,
                synoToken: currentSynoToken(),
                currentIndex: Binding(
                    get: { detailIndex ?? 0 },
                    set: { detailIndex = $0 }
                ),
                onClose: { detailIndex = nil }
            )
            .frame(minWidth: 640, minHeight: 480)
        }
        .deleteComingSoonAlert(deleteComingSoon)
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
        controller.onDeleteRequested = { count in
            deleteComingSoon.requestDelete(selectedCount: count)
        }
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
                if activeSearch == nil, case .grid = currentRoute, !env.crawl.isComplete {
                    Text(env.crawl.statusText).accessibilityIdentifier("crawl.status")
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
                            clearTempCache: { await env.tempCache.clearAll() })
                        await so.signOut()
                    }
                }
                .accessibilityIdentifier("session.signout")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            // An active search overrides whatever the sidebar is otherwise
            // routed to, matching Photos' own behavior of overlaying search
            // results on top of the current view rather than requiring the
            // user to navigate anywhere first. Clearing the query (handled
            // in the `.onChange(of: searchQuery)` above) drops straight
            // back to `currentRoute` with no further action needed here.
            if let activeSearch {
                switch LibraryContentRoute.route(
                    isComplete: env.dataSource.isReady,
                    itemCount: env.dataSource.totalCount
                ) {
                case .importing:
                    ProgressView("Searching...").accessibilityIdentifier("search.progressview")
                case .empty:
                    SearchEmptyView(query: activeSearch)
                case .grid:
                    PhotoGridView(controller: controller)
                case .failed(let message):
                    CrawlFailedView(message: message) {
                        await runSearch(activeSearch)
                    }
                }
            } else {
                switch currentRoute {
                case .grid:
                    switch LibraryContentRoute.route(
                        isComplete: env.crawl.isComplete,
                        itemCount: env.dataSource.totalCount,
                        failure: env.crawl.failure
                    ) {
                    case .importing:
                        ProgressView(env.crawl.statusText).accessibilityIdentifier("crawl.progressview")
                    case .empty:
                        EmptyLibraryView(space: env.spaceSelection.current)
                    case .grid:
                        PhotoGridView(controller: controller)
                    case .failed(let message):
                        CrawlFailedView(message: message) {
                            await env.crawl.startCrawl(space: env.spaceSelection.current)
                            await env.dataSource.refreshCount()
                            await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
                            await controller.applySnapshot()
                        }
                    }
                case .discoveryTiles:
                    if let tilesModel {
                        DiscoveryTileGridView(model: tilesModel, cache: env.discoveryCoverCache) { collection in
                            drilledInCollection = collection
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .discoveryGrid:
                    switch LibraryContentRoute.route(
                        isComplete: env.dataSource.isReady,
                        itemCount: env.dataSource.totalCount
                    ) {
                    case .importing:
                        ProgressView("Loading...").accessibilityIdentifier("discoverygrid.progressview")
                    case .empty:
                        DiscoveryGridEmptyView(title: headerTitle)
                    case .grid:
                        PhotoGridView(controller: controller)
                    case .failed(let message):
                        CrawlFailedView(message: message) {
                            if case .discoveryGrid(let collection) = currentRoute {
                                await switchCollection(to: collection)
                            }
                        }
                    }
                }
            }
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
        case .discoveryTiles: return false
        }
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
        await env.dataSource.setSearch(keyword, filters: env.searchFilters.currentFilters)
        await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
        await controller.applySnapshot()
        activeSearch = keyword
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
        case .discoveryTiles:
            // A tile grid has no photo data source to restore at all.
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

