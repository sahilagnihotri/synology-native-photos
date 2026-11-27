import Testing
import Foundation
import PhotosCore
@testable import MySynologyPhotos

struct RootRouterTests {
    @Test func validPhaseRoutesToLibrary() {
        let route = RootRouter.route(for: .valid(Session(sid: "S", synoToken: nil, username: "u", deviceDid: nil)))
        #expect(route == .library)
    }
    @Test func loggedOutRoutesToLogin() { #expect(RootRouter.route(for: .loggedOut) == .login) }
    @Test func expiredRoutesToLogin() { #expect(RootRouter.route(for: .expired) == .login) }
    @Test func needsOtpRoutesToLogin() { #expect(RootRouter.route(for: .needsOtp(username: "u")) == .login) }
    @Test func invalidRoutesToLogin() { #expect(RootRouter.route(for: .invalid(message: "x")) == .login) }
    @Test func authenticatingRoutesToLogin() { #expect(RootRouter.route(for: .authenticating) == .login) }
    @Test func restoringRoutesToLogin() { #expect(RootRouter.route(for: .restoring) == .login) }
}

/// Exercises the activation auto-sync debounce: it always syncs the first
/// time (no prior sync), skips while inside the minimum interval, and syncs
/// again once the interval has elapsed. Keeps the "do not reconcile on every
/// trivial focus change" rule honest without needing a live scene.
struct AutoSyncGateTests {
    @Test func syncsWhenNoPriorSyncHasRun() {
        #expect(AutoSyncGate.shouldSync(lastSyncAt: nil, now: Date()))
    }

    @Test func skipsWithinTheMinimumInterval() {
        let last = Date()
        let soon = last.addingTimeInterval(AutoSyncGate.minimumInterval - 1)
        #expect(!AutoSyncGate.shouldSync(lastSyncAt: last, now: soon))
    }

    @Test func syncsOnceTheMinimumIntervalHasElapsed() {
        let last = Date()
        let later = last.addingTimeInterval(AutoSyncGate.minimumInterval + 1)
        #expect(AutoSyncGate.shouldSync(lastSyncAt: last, now: later))
        // Exactly at the boundary counts as elapsed.
        let atBoundary = last.addingTimeInterval(AutoSyncGate.minimumInterval)
        #expect(AutoSyncGate.shouldSync(lastSyncAt: last, now: atBoundary))
    }

    /// A periodic tick landing right after another sync (manual Refresh or
    /// on-activation) must coalesce: the debounce clock is shared, so a tick
    /// inside the minimum interval is skipped even though the interval itself
    /// is minutes long.
    @Test func aPeriodicTickWithinTheDebounceWindowIsSkipped() {
        let last = Date()
        let shortlyAfter = last.addingTimeInterval(AutoSyncGate.minimumInterval - 1)
        #expect(!AutoSyncGate.shouldSync(lastSyncAt: last, now: shortlyAfter))
    }

    /// The periodic cadence is a light every-few-minutes tick (the brief's
    /// "roughly every 2 to 3 minutes"), and comfortably longer than the
    /// coalescing debounce so a tick is never gated purely by its own cadence.
    @Test func periodicIntervalIsRoughlyTwoToThreeMinutes() {
        #expect(AutoSyncGate.periodicInterval >= 120)
        #expect(AutoSyncGate.periodicInterval <= 180)
        #expect(AutoSyncGate.periodicInterval > AutoSyncGate.minimumInterval)
    }
}

/// Exercises the decision behind what the library area shows once the crawl
/// barrier is (or is not) complete: the importing spinner while incomplete
/// and healthy, the failed state while incomplete with a recorded failure,
/// the empty placeholder for a completed-but-empty space, and the grid once
/// there is at least one item. This is what stops a completed empty library
/// from either looking stuck on "Importing..." or rendering as a blank void
/// indistinguishable from one, and what stops a genuinely failed crawl from
/// looking identical to one still in progress.
struct LibraryContentRouteTests {
    @Test func incompleteWithNoFailureShowsImportingRegardlessOfCount() {
        #expect(LibraryContentRoute.route(isComplete: false, itemCount: 0) == .importing)
        #expect(LibraryContentRoute.route(isComplete: false, itemCount: 500) == .importing)
    }

    @Test func completeWithZeroItemsShowsEmptyState() {
        #expect(LibraryContentRoute.route(isComplete: true, itemCount: 0) == .empty)
    }

    @Test func completeWithItemsShowsGrid() {
        #expect(LibraryContentRoute.route(isComplete: true, itemCount: 1) == .grid)
        #expect(LibraryContentRoute.route(isComplete: true, itemCount: 40_000) == .grid)
    }

    @Test func incompleteWithFailureShowsFailedRegardlessOfCount() {
        #expect(LibraryContentRoute.route(isComplete: false, itemCount: 0, failure: "Network problem.") == .failed(message: "Network problem."))
        #expect(LibraryContentRoute.route(isComplete: false, itemCount: 500, failure: "Network problem.") == .failed(message: "Network problem."))
    }

    /// A failure recorded from an earlier attempt must not resurface once the
    /// barrier has actually flipped: completion is authoritative and wins.
    @Test func completeIgnoresStaleFailure() {
        #expect(LibraryContentRoute.route(isComplete: true, itemCount: 0, failure: "stale") == .empty)
        #expect(LibraryContentRoute.route(isComplete: true, itemCount: 5, failure: "stale") == .grid)
    }
}

/// Exercises the launch decision end to end against `AuthStateMachine` +
/// `FakePhotosCore`, without any SwiftUI view involved: stored session ->
/// library, no stored session -> login. This is the actual behavior the app
/// depends on (`AuthStateMachine.restore` reading the Keychain), not just the
/// pure `RootRoute` mapping above.
@MainActor
struct RootLaunchDecisionTests {
    private let host = "https://root-router-test.local:5001"

    @Test func storedSessionRoutesToLibraryAfterRestore() async throws {
        let fake = FakePhotosCore()
        let auth = AuthStateMachine(client: fake)
        let session = Session(sid: "S", synoToken: nil, username: "launchtest", deviceDid: nil)
        try KeychainSID.save(session, host: host)
        defer { try? KeychainSID.clear(host: host, username: "launchtest") }

        await auth.restore(host: host, username: "launchtest")

        #expect(RootRouter.route(for: auth.phase) == .library)
    }

    @Test func noStoredSessionRoutesToLogin() async {
        let fake = FakePhotosCore()
        let auth = AuthStateMachine(client: fake)

        await auth.restore(host: host, username: "no-such-account")

        #expect(RootRouter.route(for: auth.phase) == .login)
    }

    @Test func signOutTeardownReturnsToLogin() async throws {
        let fake = FakePhotosCore()
        let client = PhotosCoreClient(core: fake)
        let auth = AuthStateMachine(client: fake)
        let session = Session(sid: "S", synoToken: nil, username: "signouttest", deviceDid: nil)
        auth.phase = .valid(session)
        try KeychainSID.save(session, host: host)
        defer { try? KeychainSID.clear(host: host, username: "signouttest") }

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("root-router-\(UUID())")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        var tempCacheCleared = false
        let so = SignOutController(
            client: client, auth: auth,
            keychainHost: host, keychainUsername: "signouttest",
            accountCacheDir: cacheDir,
            thumbnailCache: ThumbnailCache(client: client),
            clearTempCache: { tempCacheCleared = true })

        #expect(RootRouter.route(for: auth.phase) == .library)

        await so.signOut()

        #expect(RootRouter.route(for: auth.phase) == .login)
        #expect(tempCacheCleared)
        #expect(try KeychainSID.load(host: host, username: "signouttest") == nil)
    }
}

/// R5-5 and R5-7: the active search and its debounce token live in one small
/// model so the sidebar can drop a search and an in-flight run can be refused.
@MainActor
struct SearchSessionTests {
    /// R5-7: clearing the box while a run is in flight must stop that run from
    /// committing an active search afterwards.
    @Test func aRunCancelledMidFlightCannotCommit() {
        let session = SearchSession()
        let token = session.begin()
        session.cancel()
        #expect(session.commit("dog", token: token) == false)
        #expect(session.activeKeyword == nil)
    }

    /// R5-7: a newer keystroke supersedes an older run, whichever finishes last.
    @Test func anOlderRunCannotOverwriteANewerOne() {
        let session = SearchSession()
        let old = session.begin()
        let new = session.begin()
        #expect(session.commit("dogs", token: new))
        #expect(session.commit("do", token: old) == false)
        #expect(session.activeKeyword == "dogs")
    }

    /// R5-5: cancelling (what a sidebar change does) drops an active search.
    @Test func cancelDropsTheActiveSearch() {
        let session = SearchSession()
        let token = session.begin()
        #expect(session.commit("beach", token: token))
        #expect(session.activeKeyword == "beach")
        session.cancel()
        #expect(session.activeKeyword == nil)
    }
}

/// VF-1: the view wiring behind 9fad604 and fdf4855, driven through the seams
/// the view now calls (`LibraryStartup.prepare`, `SearchSession.run`,
/// `SearchSession.dropForSidebarChange`).
@MainActor
struct LibraryWiringTests {
    private func asset(_ id: Int64) -> Asset {
        Asset(id: id, unitId: id + 10_000, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000, addedAt: nil, width: 1, height: 1,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    private func makeFake() -> FakePhotosCore {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { asset(Int64($0)) }
        fake.assetsForKeyword["dog"] = (0..<3).map { asset(Int64($0) + 9000) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        return fake
    }

    private func makeDataSource(_ fake: FakePhotosCore) -> WindowedDataSource {
        WindowedDataSource(client: PhotosCoreClient(core: fake), space: .personal, pageSize: 50)
    }

    /// 9fad604: a re-login builds the view over a data source still on a search.
    @Test func startupRestoresTheLibraryWhenTheDataSourceIsStillOnASearch() async throws {
        let fake = makeFake()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wiring-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = AppEnvironment(core: fake, accountCacheDir: dir, host: "https://wiring.local:5001")
        await env.dataSource.setSearch("dog")
        _ = await env.dataSource.loadWindow(offset: 0, limit: 50)
        #expect(env.dataSource.totalCount == 3)

        await LibraryStartup.prepare(env: env)

        #expect(env.dataSource.isShowingSpace(.personal))
        #expect(env.dataSource.totalCount == 10, "the library, not the old search, must be showing")
    }

    /// fdf4855: a sidebar change drops an active search and invalidates runs.
    @Test func aSidebarChangeDropsAnActiveSearchAndInFlightRuns() {
        let session = SearchSession()
        let token = session.begin()
        #expect(session.commit("dog", token: token))
        let inFlight = session.begin()
        #expect(session.dropForSidebarChange(queryText: "dog"))
        #expect(session.activeKeyword == nil)
        #expect(session.commit("dog", token: inFlight) == false)
    }

    @Test func aSidebarChangeWithNoSearchAndAnEmptyBoxDropsNothing() {
        let session = SearchSession()
        let token = session.begin()
        #expect(session.dropForSidebarChange(queryText: "") == false)
        #expect(session.isCurrent(token), "an idle sidebar change must not invalidate a run")
    }

    @Test func aSidebarChangeWithTextInTheBoxButNoActiveSearchStillCancels() {
        let session = SearchSession()
        let token = session.begin()
        #expect(session.dropForSidebarChange(queryText: "do"))
        #expect(session.isCurrent(token) == false)
    }

    private func runDog(
        _ session: SearchSession, token: Int?, ds: WindowedDataSource, box: String,
        events: Events
    ) async {
        await session.run(
            "dog", token: token, dataSource: ds,
            filters: SearchFilters(startTime: nil, endTime: nil),
            queryText: { box },
            prepare: { events.prepared += 1 },
            applySnapshot: { events.snapshots += 1 },
            restoreRoute: { events.restores += 1 })
    }

    @MainActor final class Events { var prepared = 0; var snapshots = 0; var restores = 0 }

    @Test func aCurrentRunShowsTheResultsAndCommits() async {
        let fake = makeFake()
        let ds = makeDataSource(fake)
        let session = SearchSession()
        let events = Events()
        await runDog(session, token: nil, ds: ds, box: "dog", events: events)
        #expect(session.activeKeyword == "dog")
        #expect(ds.totalCount == 3)
        #expect(events.prepared == 1 && events.snapshots == 1 && events.restores == 0)
    }

    /// A run already superseded before it starts must not touch the data source.
    @Test func aSupersededRunDoesNothingAtAll() async {
        let fake = makeFake()
        let ds = makeDataSource(fake)
        let session = SearchSession()
        let events = Events()
        let token = session.begin()
        session.cancel()
        await runDog(session, token: token, ds: ds, box: "", events: events)
        #expect(session.activeKeyword == nil)
        #expect(events.prepared == 0 && events.snapshots == 0 && events.restores == 0)
        #expect(fake.searchAssetsFilteredCallCount + fake.searchAssetsCallCount == 0)
    }

    /// R5-7: the box is cleared while the NAS is answering. The run must not
    /// commit or show results, and must put the route back.
    @Test func aRunClearedWhileTheNasAnswersAbandonsAndRestoresTheRoute() async {
        let fake = makeFake()
        let ds = makeDataSource(fake)
        let session = SearchSession()
        let events = Events()
        fake.onSearchCall = { session.cancel() }
        await runDog(session, token: nil, ds: ds, box: "  ", events: events)
        #expect(session.activeKeyword == nil, "a cleared run must not commit")
        #expect(events.snapshots == 0)
        #expect(events.restores == 1)
    }

    /// Superseded by a newer keystroke (box not empty): abandon, but leave the
    /// route alone because the newer run will take over.
    @Test func aRunSupersededByANewerKeystrokeAbandonsWithoutRestoring() async {
        let fake = makeFake()
        let ds = makeDataSource(fake)
        let session = SearchSession()
        let events = Events()
        fake.onSearchCall = { _ = session.begin() }
        await runDog(session, token: nil, ds: ds, box: "dogs", events: events)
        #expect(session.activeKeyword == nil)
        #expect(events.snapshots == 0)
        #expect(events.restores == 0)
    }
}

/// VF-1 wiring guard. The four view hunks (LibraryView `.task`, the sidebar
/// drop and `runSearch`, the RecentlyDeletedView context menu and the editor
/// `.alert`) cannot be driven without a scene, so the behaviour lives in the
/// seams tested above and this pins that each view still calls its seam.
/// Reverting a view hunk to its old inline code fails here.
struct ViewWiringGuardTests {
    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MySynologyPhotos")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func libraryViewCallsTheStartupAndSearchSeams() throws {
        let s = try source("RootView.swift")
        #expect(s.contains("await LibraryStartup.prepare(env: env)"))
        #expect(s.contains("searchSession.dropForSidebarChange(queryText: searchQuery)"))
        #expect(s.contains("await searchSession.run("))
    }

    @Test func recentlyDeletedContextMenuCallsTheEntryTargetingSeams() throws {
        let s = try source("Trash/RecentlyDeletedView.swift")
        #expect(s.contains("model.restoreFromContextMenu(item.recyclePath)"))
        #expect(s.contains("model.requestEmptyFromContextMenu(item.recyclePath)"))
        #expect(!s.contains("model.toggle(item.recyclePath) }\n                                Task"))
    }

    @Test func editorShowsTheSaveFailureAlertFromTheModelBinding() throws {
        let s = try source("Detail/PhotoEditorView.swift")
        #expect(s.contains(".alert("))
        #expect(s.contains("\"Could Not Save\""))
        #expect(s.contains("model.isShowingSaveFailure"))
    }
}
