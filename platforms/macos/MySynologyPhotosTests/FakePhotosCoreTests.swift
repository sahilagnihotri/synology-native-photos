import Foundation
import Testing
import PhotosCore
@testable import MySynologyPhotos

struct FakePhotosCoreTests {
    // MARK: - Login

    @Test func fakeLoginReturnsConfiguredSession() async throws {
        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "SID123", synoToken: nil, username: "photo", deviceDid: nil))
        let conn = Connection(host: "https://192.168.1.10:5001", verifyTls: true, pinnedCertDer: nil, allowUntrustedTls: false)

        let session = try await fake.login(connection: conn, username: "photo", password: "pw", otpCode: nil, deviceToken: nil)

        #expect(session.sid == "SID123")
        #expect(fake.loginCallCount == 1)
    }

    @Test func fakeLoginThrowsOtpRequired() async {
        let fake = FakePhotosCore()
        fake.loginResult = .failure(CoreError.OtpRequired)
        let conn = Connection(host: "https://x:5001", verifyTls: true, pinnedCertDer: nil, allowUntrustedTls: false)

        await #expect(throws: CoreError.self) {
            _ = try await fake.login(connection: conn, username: "u", password: "p", otpCode: nil, deviceToken: nil)
        }
    }

    @Test func fakeLoginRetryWithOtpSucceeds() async throws {
        let fake = FakePhotosCore()
        fake.loginResult = .failure(CoreError.OtpRequired)
        let conn = Connection(host: "https://x:5001", verifyTls: true, pinnedCertDer: nil, allowUntrustedTls: false)

        await #expect(throws: CoreError.self) {
            _ = try await fake.login(connection: conn, username: "u", password: "p", otpCode: nil, deviceToken: nil)
        }

        fake.loginResult = .success(Session(sid: "SID999", synoToken: "tok", username: "u", deviceDid: "dev"))
        let session = try await fake.login(connection: conn, username: "u", password: "p", otpCode: "123456", deviceToken: nil)

        #expect(session.sid == "SID999")
        #expect(fake.loginCallCount == 2)
        #expect(fake.lastOtpCode == .some("123456"))
    }

    // MARK: - Session restore / sign out

    @Test func fakeRestoreSessionReturnsConfiguredState() async throws {
        let fake = FakePhotosCore()
        fake.restoreResult = .success(.expired)
        let conn = Connection(host: "https://192.168.1.10:5001", verifyTls: true, pinnedCertDer: nil, allowUntrustedTls: false)
        let session = Session(sid: "SID123", synoToken: nil, username: "photo", deviceDid: nil)

        let state = try await fake.restoreSession(connection: conn, session: session)

        #expect(state == .expired)
        #expect(fake.restoreSessionCallCount == 1)
    }

    @Test func fakeSignOutIncrementsCallCount() async throws {
        let fake = FakePhotosCore()

        try await fake.signOut()
        try await fake.signOut()

        #expect(fake.signOutCallCount == 2)
    }

    @Test func fakeSignOutPropagatesConfiguredFailure() async {
        let fake = FakePhotosCore()
        fake.signOutResult = .failure(CoreError.Network(message: "offline"))

        await #expect(throws: CoreError.self) {
            try await fake.signOut()
        }
    }

    // MARK: - Capabilities

    @Test func fakeProbeCapabilitiesReturnsConfiguredList() async throws {
        let fake = FakePhotosCore()
        fake.capabilitiesResult = .success([
            ApiCapability(name: "SYNO.Foto.Browse.Item", path: "entry.cgi", minVersion: 1, maxVersion: 4)
        ])

        let caps = try await fake.probeCapabilities()

        #expect(caps.count == 1)
        #expect(caps.first?.name == "SYNO.Foto.Browse.Item")
    }

    // MARK: - Fetch assets / albums (windowed local reads)

    @Test func fakeFetchAssetsReturnsWindow() throws {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<100).map { Self.asset(id: Int64($0)) }

        let window = try fake.fetchAssets(space: .personal, offset: 10, limit: 5)

        #expect(window.count == 5)
        #expect(window.first?.id == 10)
        #expect(window.last?.id == 14)
    }

    @Test func fakeFetchAssetsPastEndReturnsEmpty() throws {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<10).map { Self.asset(id: Int64($0)) }

        let window = try fake.fetchAssets(space: .personal, offset: 20, limit: 5)

        #expect(window.isEmpty)
    }

    @Test func fakeAssetCountReflectsConfiguredSpace() throws {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<42).map { Self.asset(id: Int64($0)) }

        #expect(try fake.assetCount(space: .personal) == 42)
        #expect(try fake.assetCount(space: .shared) == 0)
    }

    @Test func fakeFetchLocalAlbumsReturnsConfiguredList() throws {
        let fake = FakePhotosCore()
        fake.albums[.shared] = [
            Album(id: 1, name: "Trip", itemCount: 12, coverCacheKey: "ck1", coverUnitId: nil, isShared: false, isSmart: false, space: .shared)
        ]

        let albums = try fake.fetchLocalAlbums(space: .shared)

        #expect(albums.count == 1)
        #expect(albums.first?.name == "Trip")
        #expect(try fake.fetchLocalAlbums(space: .personal).isEmpty)
    }

    // MARK: - Crawl

    @Test func fakeCrawlSpaceEmitsProgressThenCompletes() async throws {
        let fake = FakePhotosCore()
        fake.crawlProgressToEmit = [
            CrawlProgress(space: .personal, done: 10, total: 100, complete: false),
            CrawlProgress(space: .personal, done: 50, total: 100, complete: false),
        ]
        fake.crawlFinal[.personal] = CrawlProgress(space: .personal, done: 100, total: 100, complete: true)
        let observer = RecordingObserver()

        let result = try await fake.crawlSpace(space: .personal, observer: observer)

        #expect(observer.received.map(\.done) == [10, 50])
        #expect(result.complete == true)
        #expect(result.done == 100)
        #expect(fake.crawlSpaceCallCount == 1)
    }

    @Test func fakeReconcileDeltaReturnsFinalProgress() async throws {
        let fake = FakePhotosCore()
        fake.crawlFinal[.personal] = CrawlProgress(space: .personal, done: 5, total: 5, complete: true)

        let result = try await fake.reconcileDelta(space: .personal)

        #expect(result.done == 5)
        #expect(fake.reconcileDeltaCallCount == 1)
    }

    @Test func fakeCrawlProgressReadsConfiguredSnapshotWithoutNetwork() throws {
        let fake = FakePhotosCore()
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 30, total: 100, complete: false)

        let progress = try fake.crawlProgress(space: .personal)

        #expect(progress.done == 30)
        #expect(progress.complete == false)
    }

    // MARK: - Media bytes

    @Test func fakeThumbnailReturnsConfiguredData() async throws {
        let fake = FakePhotosCore()
        fake.thumbnailResult = .success(ThumbnailData(cachedPath: "/tmp/thumb.jpg", bytes: Data([1, 2, 3])))

        let thumb = try await fake.thumbnail(space: .personal, unitId: 7, cacheKey: "ck7", size: .m)

        #expect(thumb.cachedPath == "/tmp/thumb.jpg")
        #expect(fake.thumbnailCallCount == 1)
        #expect(fake.lastThumbnailRequest?.unitId == 7)
    }

    @Test func fakeDownloadOriginalReturnsConfiguredPath() async throws {
        let fake = FakePhotosCore()
        fake.downloadResult = .success("/tmp/downloaded.jpg")

        let path = try await fake.downloadOriginal(space: .personal, unitId: 9, cacheKey: "ck9")

        #expect(path == "/tmp/downloaded.jpg")
        #expect(fake.downloadOriginalCallCount == 1)
        #expect(fake.lastDownloadRequest?.cacheKey == "ck9")
    }

    // MARK: - Fixtures

    static func asset(id: Int64) -> Asset {
        Asset(id: id, unitId: id + 10_000, cacheKey: "ck\(id)", filename: "IMG_\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000 + id, addedAt: nil, width: 4032, height: 3024,
              fileSize: nil, space: .personal, serverVersion: id)
    }
}

/// Records every progress event delivered by `crawlSpace` for assertion.
private final class RecordingObserver: FfiCrawlObserver, @unchecked Sendable {
    private(set) var received: [CrawlProgress] = []

    func onProgress(progress: CrawlProgress) {
        received.append(progress)
    }
}
