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
