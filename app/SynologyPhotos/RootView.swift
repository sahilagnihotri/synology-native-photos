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

/// The three things the completed-or-not library area can show at any one
/// time. Purely a function of the crawl barrier plus the current item
/// count, kept as a standalone type (mirroring `RootRouter` above) so the
/// decision is testable without a live `AppEnvironment` or any AppKit view.
enum LibraryContentRoute: Equatable {
    case importing
    case empty
    case grid
}

extension LibraryContentRoute {
    /// `isComplete` must come only from `CrawlProgress.complete` (the
    /// barrier `CrawlProgressModel` mirrors); this never treats a nonzero
    /// count as evidence of completeness on its own, since a mid-crawl
    /// count also grows. Once complete, an empty library and a nonempty one
    /// are distinguished purely by `itemCount`, so the importing spinner
    /// never lingers after the barrier flips.
    static func route(isComplete: Bool, itemCount: Int) -> LibraryContentRoute {
        guard isComplete else { return .importing }
        return itemCount > 0 ? .grid : .empty
    }
}

/// Library scene: space toggle + importing progress + grid + detail.
///
/// Grid item selection opens `DetailQuickLookView` in a sheet: `selected`
/// is populated from `PhotoGridController.onSelect`, which the controller
/// invokes with the asset for a newly selected index path (nil clears the
/// sheet on deselect). This is the wiring `DetailQuickLookView`'s own task
/// (51) explicitly deferred to here.
struct LibraryView: View {
    let env: AppEnvironment
    @State private var controller: PhotoGridController
    @State private var selected: Asset?

    init(env: AppEnvironment) {
        self.env = env
        let c = PhotoGridController(dataSource: env.dataSource, cache: env.thumbnailCache)
        _controller = State(initialValue: c)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                SpaceToggleView(selection: env.spaceSelection, dataSource: env.dataSource) {
                    // `setSpace` (already run by the toggle before this
                    // closure fires) only re-queries the local index for the
                    // newly selected space; it never crawls. A space visited
                    // for the first time therefore has an empty local index
                    // until something crawls it, which would otherwise look
                    // identical to a genuinely empty space. Running the
                    // crawl here (a no-op per `Crawler::crawl_space` if the
                    // space's barrier is already set) is what makes
                    // switching to a not-yet-crawled space actually populate
                    // it instead of showing a false empty state.
                    await env.crawl.startCrawl(space: env.spaceSelection.current)
                    await env.dataSource.refreshCount()
                    await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
                    await controller.applySnapshot()
                }
                Spacer()
                if !env.crawl.isComplete {
                    Text(env.crawl.statusText).accessibilityIdentifier("crawl.status")
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
            switch LibraryContentRoute.route(
                isComplete: env.crawl.isComplete,
                itemCount: env.dataSource.totalCount
            ) {
            case .importing:
                ProgressView(env.crawl.statusText).accessibilityIdentifier("crawl.progressview")
            case .empty:
                EmptyLibraryView(space: env.spaceSelection.current)
            case .grid:
                PhotoGridView(controller: controller)
            }
        }
        .task {
            controller.onSelect = { asset in selected = asset }
            await env.crawl.startCrawl(space: env.spaceSelection.current)
            await env.dataSource.refreshCount()
            await env.dataSource.loadWindow(offset: 0, limit: env.dataSource.pageSize)
            await controller.applySnapshot()
        }
        .sheet(item: $selected) { asset in
            DetailQuickLookView(
                asset: asset,
                space: env.dataSource.space,
                client: env.client,
                cache: env.tempCache)
            .frame(minWidth: 640, minHeight: 480)
        }
    }

    /// The signed-in account username, read from the current auth phase.
    private func currentUsername() -> String {
        if case .valid(let session) = env.auth.phase { return session.username }
        return ""
    }
}

// `Asset.id` (an `Int64`) already uniquely identifies a row within its own
// space; that's enough for SwiftUI's `sheet(item:)` to key off directly.
extension Asset: @retroactive Identifiable {}
