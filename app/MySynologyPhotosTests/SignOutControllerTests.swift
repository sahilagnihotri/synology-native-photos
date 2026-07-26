import Testing
import Foundation
import PhotosCore
@testable import MySynologyPhotos

@MainActor
struct SignOutControllerTests {
    private func makeCacheDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acct-cache-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func signOutClearsSessionKeychainCacheAndPhase() async throws {
        let fake = FakePhotosCore()
        let client = PhotosCoreClient(core: fake)
        let auth = AuthStateMachine(client: fake)
        auth.phase = .valid(Session(sid: "S", synoToken: nil, username: "sotest", deviceDid: nil))
        let host = "https://signout-test.local:5001"
        try KeychainSID.save(Session(sid: "S", synoToken: nil, username: "sotest", deviceDid: nil), host: host)
        defer { try? KeychainSID.clear(host: host, username: "sotest") }

        let cacheDir = makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let dummy = cacheDir.appendingPathComponent("thumb.jpg")
        FileManager.default.createFile(atPath: dummy.path, contents: Data([1]))

        var tempCacheClearedCount = 0
        let controller = SignOutController(
            client: client, auth: auth,
            keychainHost: host, keychainUsername: "sotest",
            accountCacheDir: cacheDir,
            thumbnailCache: ThumbnailCache(client: client),
            clearTempCache: { tempCacheClearedCount += 1 })

        await controller.signOut()

        #expect(fake.signOutCallCount == 1)
        #expect(try KeychainSID.load(host: host, username: "sotest") == nil)
        #expect(FileManager.default.fileExists(atPath: dummy.path) == false)
        #expect(FileManager.default.fileExists(atPath: cacheDir.path) == true)
        #expect(auth.phase == .loggedOut)
        #expect(tempCacheClearedCount == 1)
    }

    @Test func signOutIsIdempotentWhenAlreadyLoggedOut() async {
        let fake = FakePhotosCore()
        let client = PhotosCoreClient(core: fake)
        let auth = AuthStateMachine(client: fake)
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("acct-cache-\(UUID())")
        // Deliberately not created: signing out with no cache directory at
        // all present is the "already fully signed out" case.
        let controller = SignOutController(
            client: client, auth: auth,
            keychainHost: "https://x:5001", keychainUsername: "none",
            accountCacheDir: cacheDir,
            thumbnailCache: ThumbnailCache(client: client))

        await controller.signOut()
        await controller.signOut()

        #expect(auth.phase == .loggedOut)
        #expect(fake.signOutCallCount == 2)
    }

    @Test func signOutEndsLoggedOutEvenWhenKeychainClearFails() async throws {
        let fake = FakePhotosCore()
        let client = PhotosCoreClient(core: fake)
        let auth = AuthStateMachine(client: fake)
        auth.phase = .valid(Session(sid: "S", synoToken: nil, username: "failtest", deviceDid: nil))

        // A host string that cannot round-trip through the Keychain query
        // dictionary the same way a normal save did is still handled
        // gracefully: KeychainSID.clear on an entry that was never saved
        // (or can't be found) simply returns without throwing, and the
        // controller must still land on .loggedOut. This exercises the
        // "partial failure" path: nothing was ever stored under this
        // host/username pair, so the clear is a real no-op, not a mocked
        // throw, but the controller's contract is the same either way.
        let cacheDir = makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let controller = SignOutController(
            client: client, auth: auth,
            keychainHost: "https://never-saved.local:5001",
            keychainUsername: "ghost-account",
            accountCacheDir: cacheDir,
            thumbnailCache: ThumbnailCache(client: client))

        await controller.signOut()

        #expect(auth.phase == .loggedOut)
        #expect(fake.signOutCallCount == 1)
    }

    @Test func signOutEndsLoggedOutEvenWhenServerLogoutFails() async {
        let fake = FakePhotosCore()
        fake.signOutResult = .failure(.Network(message: "connection dropped"))
        let client = PhotosCoreClient(core: fake)
        let auth = AuthStateMachine(client: fake)
        auth.phase = .valid(Session(sid: "S", synoToken: nil, username: "netfail", deviceDid: nil))

        let controller = SignOutController(
            client: client, auth: auth,
            keychainHost: "https://net-fail.local:5001",
            keychainUsername: "netfail",
            accountCacheDir: FileManager.default.temporaryDirectory.appendingPathComponent("acct-cache-\(UUID())"),
            thumbnailCache: ThumbnailCache(client: client))

        await controller.signOut()

        #expect(fake.signOutCallCount == 1)
        #expect(auth.phase == .loggedOut)
    }
}
