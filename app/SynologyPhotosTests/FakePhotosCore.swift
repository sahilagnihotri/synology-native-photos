import Foundation
import PhotosCore
@testable import SynologyPhotos

/// Deterministic in-memory test double conforming to `PhotosCoreProtocol`.
///
/// Every method result is driven by a script the test configures up front
/// (a `Result`, a canned array, a list of progress events to emit) so tests
/// stay fast, offline, and free of any dependency on the real Rust core or
/// a live NAS. Call counts and last-seen arguments are recorded for tests
/// that need to assert on how the fake was used, not just what it returned.
final class FakePhotosCore: PhotosCoreProtocol, @unchecked Sendable {
    // MARK: - Scripted results

    var loginResult: Result<Session, CoreError> = .success(
        Session(sid: "FAKE", synoToken: nil, username: "photo", deviceDid: nil))
    var restoreResult: Result<SessionState, CoreError> = .success(.valid)
    var signOutResult: Result<Void, CoreError> = .success(())
    var capabilitiesResult: Result<[ApiCapability], CoreError> = .success([])
    var thumbnailResult: Result<ThumbnailData, CoreError> =
        .success(ThumbnailData(cachedPath: "/tmp/fake.jpg", bytes: Data()))
    var downloadResult: Result<String, CoreError> = .success("/tmp/original.jpg")

    /// Progress events replayed to the observer during `crawlSpace`, in order.
    var crawlProgressToEmit: [CrawlProgress] = []
    /// Final value returned by `crawlSpace` / `reconcileDelta` per space.
    var crawlFinal: [Space: CrawlProgress] = [:]
    /// Value returned by the synchronous `crawlProgress(space:)` read per space.
    var progressBySpace: [Space: CrawlProgress] = [:]

    /// Canned local data, keyed by space, windowed by `fetchAssets`.
    var assets: [Space: [Asset]] = [:]
    var albums: [Space: [Album]] = [:]

    // MARK: - Call tracking

    private(set) var loginCallCount = 0
    private(set) var restoreSessionCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var probeCapabilitiesCallCount = 0
    private(set) var crawlSpaceCallCount = 0
    private(set) var reconcileDeltaCallCount = 0
    private(set) var thumbnailCallCount = 0
    private(set) var downloadOriginalCallCount = 0

    private(set) var lastOtpCode: String??
    private(set) var lastLoginConnection: Connection?
    private(set) var lastCrawledSpace: Space?
    private(set) var lastReconciledSpace: Space?
    private(set) var lastThumbnailRequest: (space: Space, assetId: Int64, cacheKey: String, size: ThumbnailSize)?
    private(set) var lastDownloadRequest: (space: Space, assetId: Int64, cacheKey: String)?

    init() {}

    // MARK: - Auth

    func login(
        connection: Connection,
        username: String,
        password: String,
        otpCode: String?
    ) async throws -> Session {
        loginCallCount += 1
        lastOtpCode = .some(otpCode)
        lastLoginConnection = connection
        return try loginResult.get()
    }

    func restoreSession(connection: Connection, session: Session) async throws -> SessionState {
        restoreSessionCallCount += 1
        return try restoreResult.get()
    }

    func signOut() async throws {
        signOutCallCount += 1
        try signOutResult.get()
    }

    // MARK: - Capability

    func probeCapabilities() async throws -> [ApiCapability] {
        probeCapabilitiesCallCount += 1
        return try capabilitiesResult.get()
    }

    // MARK: - Crawl / sync

    func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress {
        crawlSpaceCallCount += 1
        lastCrawledSpace = space
        for progress in crawlProgressToEmit {
            observer.onProgress(progress: progress)
        }
        return crawlFinal[space] ?? CrawlProgress(space: space, done: 0, total: 0, complete: true)
    }

    func reconcileDelta(space: Space) async throws -> CrawlProgress {
        reconcileDeltaCallCount += 1
        lastReconciledSpace = space
        return crawlFinal[space] ?? CrawlProgress(space: space, done: 0, total: 0, complete: true)
    }

    func crawlProgress(space: Space) throws -> CrawlProgress {
        progressBySpace[space] ?? CrawlProgress(space: space, done: 0, total: 0, complete: false)
    }

    // MARK: - Windowed read (local only)

    func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
        let all = assets[space] ?? []
        let start = Int(offset)
        guard start < all.count else { return [] }
        let end = min(start + Int(limit), all.count)
        return Array(all[start..<end])
    }

    func assetCount(space: Space) throws -> UInt64 {
        UInt64((assets[space] ?? []).count)
    }

    func fetchAlbums(space: Space) throws -> [Album] {
        albums[space] ?? []
    }

    // MARK: - Media bytes

    func thumbnail(
        space: Space,
        assetId: Int64,
        cacheKey: String,
        size: ThumbnailSize
    ) async throws -> ThumbnailData {
        thumbnailCallCount += 1
        lastThumbnailRequest = (space, assetId, cacheKey, size)
        return try thumbnailResult.get()
    }

    func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String {
        downloadOriginalCallCount += 1
        lastDownloadRequest = (space, assetId, cacheKey)
        return try downloadResult.get()
    }
}
