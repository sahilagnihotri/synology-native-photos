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

    /// Artificial delay applied before every `thumbnail(...)` call resolves.
    /// Zero by default so existing tests that don't care about timing are
    /// unaffected. Set this to force a load to still be in flight while a
    /// test performs a reuse, reproducing the race a plain `Task.yield()`
    /// cannot: `Task.yield()` only cedes the thread for one hop, so a
    /// zero-delay fake resolves before the test ever gets a chance to
    /// reuse the cell, which is why the previous reuse test never actually
    /// exercised the guard's recheck path.
    var thumbnailDelay: Duration = .zero

    /// Per-asset override for `thumbnailDelay`, keyed by `assetId`. Checked
    /// first; falls back to `thumbnailDelay` when an asset has no entry.
    /// Lets a test race a slow load for one asset against a fast (or
    /// instant) load for another without a single global delay slowing
    /// down every call in the same test.
    var thumbnailDelayByAssetId: [Int64: Duration] = [:]

    /// Per-asset override for `thumbnailResult`, keyed by `assetId`. Checked
    /// first; falls back to `thumbnailResult` when an asset has no entry.
    /// Needed alongside `thumbnailDelayByAssetId`: reassigning the shared
    /// `thumbnailResult` for a second asset while a first asset's delayed
    /// call is still sleeping would make that first call read back the
    /// second asset's result once it wakes, since both calls share the same
    /// var. Keying by asset id keeps each call's result pinned to the
    /// asset it was issued for regardless of resolution order.
    var thumbnailResultByAssetId: [Int64: Result<ThumbnailData, CoreError>] = [:]

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
        let delay = thumbnailDelayByAssetId[assetId] ?? thumbnailDelay
        // Captured before the delay, not read again after it: this is what
        // pins the result to the asset this call was made for even if
        // another asset's call reassigns the shared `thumbnailResult` var
        // while this call is still asleep.
        let result = thumbnailResultByAssetId[assetId] ?? thumbnailResult
        if delay > .zero {
            // Deliberately a *detached* sleep, not a plain `try? await
            // Task.sleep(for: delay)` inline here. `PhotoCellView` cancels
            // its `loadTask` on reuse, and that cancellation propagates
            // into any `Task.sleep` running as part of that same task tree,
            // making it throw (and, with `try?`, silently resume) almost
            // instantly instead of actually waiting out `delay`. That would
            // quietly defeat the whole point of this knob: it simulates a
            // real network/FFI call to the NAS, which does not abort the
            // instant Swift-side cancellation is requested. Detaching keeps
            // this sleep on its own task, immune to the caller's
            // cancellation, so the load stays genuinely in flight for the
            // full `delay`.
            await Task.detached { try? await Task.sleep(for: delay) }.value
        }
        return try result.get()
    }

    func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String {
        downloadOriginalCallCount += 1
        lastDownloadRequest = (space, assetId, cacheKey)
        return try downloadResult.get()
    }
}
