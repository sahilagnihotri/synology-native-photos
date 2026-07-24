import Testing
import Foundation
import PhotosCore
@testable import SynologyPhotos

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

/// Exercises the decision behind what the library area shows once the crawl
/// barrier is (or is not) complete: the importing spinner while incomplete,
/// the empty placeholder for a completed-but-empty space, and the grid once
/// there is at least one item. This is what stops a completed empty library
/// from either looking stuck on "Importing..." or rendering as a blank void
/// indistinguishable from one.
struct LibraryContentRouteTests {
    @Test func incompleteAlwaysShowsImportingRegardlessOfCount() {
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
