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

    /// Result for `videoPlaybackSource`. Defaults to a plausible LocalFile
    /// payload so a test that never scripts it still gets something sensible.
    var videoPlaybackSourceResult: Result<VideoPlaybackSource, CoreError> = .success(
        .localFile(path: "/tmp/original.mov"))

    /// Result for `fetchCertificate`. Defaults to a plausible TOFU-approval
    /// payload so a test that never touches this still gets something
    /// sensible if it happens to call the method.
    var fetchCertificateResult: Result<CertInfo, CoreError> = .success(
        CertInfo(der: Data([0xCE, 0x27]), sha256Hex: "aa:bb:cc:dd", subject: "CN=fake.nas.local"))

    // MARK: - Trash (hybrid safe-delete) scripted results

    /// Result for `ensureTrashAlbum`. Defaults to a plausible app-owned
    /// Recently Deleted album so a test that never scripts it still gets
    /// something sensible back.
    var ensureTrashAlbumResult: Result<Album, CoreError> = .success(
        Album(id: 9_000, name: "Recently Deleted", itemCount: 0, coverCacheKey: nil,
              coverUnitId: nil, isShared: false, isSmart: false, space: .personal))
    var deleteToTrashResult: Result<Void, CoreError> = .success(())
    var restoreFromTrashResult: Result<Void, CoreError> = .success(())
    var permanentlyDeleteResult: Result<Void, CoreError> = .success(())
    var reconcileTrashResult: Result<Void, CoreError> = .success(())
    /// Canned trashed assets per space, windowed by `fetchTrash` exactly the
    /// way `assets` is windowed by `fetchAssets`.
    var trash: [Space: [Asset]] = [:]

    /// When set, `login` only succeeds (skipping the `OtpRequired` path)
    /// when the caller's `deviceToken` exactly matches this value; any
    /// other token (including `nil`) is treated as if none had been given
    /// at all and falls back to `loginResult`. Mirrors the real DSM
    /// behavior documented on `synology_api::auth::login`: a stale/expired
    /// device token fails closed into the same `OtpRequired` an absent
    /// token would produce, it never itself grants a session.
    ///
    /// Left `nil` (the default) means device-token gating is off entirely
    /// and `login` always just returns `loginResult` regardless of what
    /// token (if any) was passed, which is what every pre-existing login
    /// test in this suite relies on.
    var acceptedDeviceToken: String?

    /// Session returned once `acceptedDeviceToken` matches. Defaults to
    /// `loginResult`'s success value when unset.
    var deviceTokenLoginResult: Result<Session, CoreError>?

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
    /// Overrides the outcome of `crawlSpace` entirely when set. Lets a test
    /// simulate a crawl that fails outright (e.g. network drop mid-crawl)
    /// rather than always succeeding with `crawlFinal`.
    var crawlSpaceResult: Result<Void, CoreError>?
    /// Value returned by the synchronous `crawlProgress(space:)` read per space.
    var progressBySpace: [Space: CrawlProgress] = [:]

    /// Canned local data, keyed by space, windowed by `fetchAssets`.
    var assets: [Space: [Asset]] = [:]
    var albums: [Space: [Album]] = [:]

    // MARK: - Discovery browse

    var peopleResult: Result<[Person], CoreError> = .success([])
    var placesResult: Result<[Place], CoreError> = .success([])
    var subjectsResult: Result<[Subject], CoreError> = .success([])
    var tagsResult: Result<[Tag], CoreError> = .success([])
    var liveAlbumsResult: Result<[Album], CoreError> = .success([])
    /// Canned assets per collection, windowed the same way `assets` is for
    /// `fetchAssets`. Keyed by the collection's own equality (DiscoveryCollection
    /// conforms to Equatable via its generated Hashable/Equatable), so a test
    /// can script different photos per person/place/tag/favorites.
    var assetsForCollection: [DiscoveryCollection: [Asset]] = [:]
    /// Overrides `fetchAssetsFor` entirely when set, taking precedence over
    /// `assetsForCollection`; lets a test simulate a fetch failure (e.g. the
    /// Subjects collection with no working filter) without needing a real
    /// error path through the windowing logic below.
    var fetchAssetsForResult: Result<[Asset], CoreError>?

    /// Canned assets per keyword, windowed the same way `assetsForCollection`
    /// is for `fetchAssetsFor`. Keyed by the exact keyword string a test
    /// scripts, so different keywords can return different result sets.
    var assetsForKeyword: [String: [Asset]] = [:]
    /// Overrides `searchAssets` entirely when set, taking precedence over
    /// `assetsForKeyword`; lets a test simulate a search failure without
    /// needing a real error path through the windowing logic below.
    var searchAssetsResult: Result<[Asset], CoreError>?

    /// Overrides `searchAssetsFiltered` entirely when set; falls back to
    /// `assetsForKeyword` (ignoring the filters) when unset, matching the
    /// plain `searchAssets` fallback above -- a test that only cares about
    /// the keyword-routing part of the fake does not also need to script
    /// filters.
    var searchAssetsFilteredResult: Result<[Asset], CoreError>?
    /// Result for `fetchSearchFacets`. Defaults to an empty catalog.
    var searchFacetsResult: Result<SearchFacets, CoreError> = .success(
        SearchFacets(cameras: [], apertures: [], geocodings: [], mediaTypes: []))

    private(set) var fetchPeopleCallCount = 0
    private(set) var fetchPlacesCallCount = 0
    private(set) var fetchSubjectsCallCount = 0
    private(set) var fetchTagsCallCount = 0
    private(set) var fetchLiveAlbumsCallCount = 0
    private(set) var fetchAssetsForCallCount = 0
    private(set) var searchAssetsCallCount = 0
    private(set) var searchAssetsFilteredCallCount = 0
    private(set) var fetchSearchFacetsCallCount = 0
    private(set) var lastFetchAssetsForCollection: DiscoveryCollection?
    private(set) var lastSearchKeyword: String?
    private(set) var lastSearchFilters: SearchFilters?

    // MARK: - Call tracking

    private(set) var loginCallCount = 0
    private(set) var restoreSessionCallCount = 0
    private(set) var signOutCallCount = 0
    private(set) var probeCapabilitiesCallCount = 0
    private(set) var crawlSpaceCallCount = 0
    private(set) var reconcileDeltaCallCount = 0
    private(set) var thumbnailCallCount = 0
    private(set) var downloadOriginalCallCount = 0
    private(set) var videoPlaybackSourceCallCount = 0
    private(set) var fetchCertificateCallCount = 0

    private(set) var lastOtpCode: String??
    private(set) var lastDeviceToken: String??
    private(set) var lastLoginConnection: Connection?
    private(set) var lastFetchCertificateHost: String?
    private(set) var lastCrawledSpace: Space?
    private(set) var lastReconciledSpace: Space?
    private(set) var lastThumbnailRequest: (space: Space, unitId: Int64, cacheKey: String, size: ThumbnailSize)?
    private(set) var lastDownloadRequest: (space: Space, unitId: Int64, cacheKey: String)?
    private(set) var lastVideoPlaybackRequest: (space: Space, asset: Asset)?

    // MARK: - Trash call tracking

    private(set) var ensureTrashAlbumCallCount = 0
    private(set) var deleteToTrashCallCount = 0
    private(set) var restoreFromTrashCallCount = 0
    private(set) var permanentlyDeleteCallCount = 0
    private(set) var reconcileTrashCallCount = 0
    private(set) var fetchTrashCallCount = 0
    private(set) var trashCountCallCount = 0

    private(set) var lastDeleteToTrashIds: [Int64]?
    private(set) var lastRestoreFromTrashIds: [Int64]?
    private(set) var lastPermanentlyDeleteIds: [Int64]?
    private(set) var lastEnsureTrashAlbumSpace: Space?
    private(set) var lastDeleteToTrashSpace: Space?
    private(set) var lastRestoreFromTrashSpace: Space?
    private(set) var lastPermanentlyDeleteSpace: Space?
    private(set) var lastReconciledTrashSpace: Space?

    init() {}

    // MARK: - Auth

    func login(
        connection: Connection,
        username: String,
        password: String,
        otpCode: String?,
        deviceToken: String?
    ) async throws -> Session {
        loginCallCount += 1
        lastOtpCode = .some(otpCode)
        lastDeviceToken = .some(deviceToken)
        lastLoginConnection = connection
        if let acceptedDeviceToken, let deviceToken, deviceToken == acceptedDeviceToken {
            return try (deviceTokenLoginResult ?? loginResult).get()
        }
        return try loginResult.get()
    }

    func fetchCertificate(host: String) async throws -> CertInfo {
        fetchCertificateCallCount += 1
        lastFetchCertificateHost = host
        return try fetchCertificateResult.get()
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
        if let crawlSpaceResult {
            try crawlSpaceResult.get()
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

    func fetchLocalAlbums(space: Space) throws -> [Album] {
        albums[space] ?? []
    }

    // MARK: - Media bytes

    func thumbnail(
        space: Space,
        unitId: Int64,
        cacheKey: String,
        size: ThumbnailSize
    ) async throws -> ThumbnailData {
        thumbnailCallCount += 1
        lastThumbnailRequest = (space, unitId, cacheKey, size)
        let delay = thumbnailDelayByAssetId[unitId] ?? thumbnailDelay
        // Captured before the delay, not read again after it: this is what
        // pins the result to the asset this call was made for even if
        // another asset's call reassigns the shared `thumbnailResult` var
        // while this call is still asleep.
        let result = thumbnailResultByAssetId[unitId] ?? thumbnailResult
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

    func downloadOriginal(space: Space, unitId: Int64, cacheKey: String) async throws -> String {
        downloadOriginalCallCount += 1
        lastDownloadRequest = (space, unitId, cacheKey)
        return try downloadResult.get()
    }

    func videoPlaybackSource(space: Space, asset: Asset) async throws -> VideoPlaybackSource {
        videoPlaybackSourceCallCount += 1
        lastVideoPlaybackRequest = (space, asset)
        return try videoPlaybackSourceResult.get()
    }

    // MARK: - Trash (hybrid safe-delete)

    func ensureTrashAlbum(space: Space) async throws -> Album {
        ensureTrashAlbumCallCount += 1
        lastEnsureTrashAlbumSpace = space
        return try ensureTrashAlbumResult.get()
    }

    func deleteToTrash(space: Space, assetIds: [Int64]) async throws {
        deleteToTrashCallCount += 1
        lastDeleteToTrashSpace = space
        lastDeleteToTrashIds = assetIds
        try deleteToTrashResult.get()
    }

    func restoreFromTrash(space: Space, assetIds: [Int64]) async throws {
        restoreFromTrashCallCount += 1
        lastRestoreFromTrashSpace = space
        lastRestoreFromTrashIds = assetIds
        try restoreFromTrashResult.get()
    }

    func fetchTrash(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
        fetchTrashCallCount += 1
        return try window(trash[space] ?? [], offset: offset, limit: limit)
    }

    func trashCount(space: Space) throws -> UInt32 {
        trashCountCallCount += 1
        return UInt32((trash[space] ?? []).count)
    }

    func permanentlyDelete(space: Space, assetIds: [Int64]) async throws {
        permanentlyDeleteCallCount += 1
        lastPermanentlyDeleteSpace = space
        lastPermanentlyDeleteIds = assetIds
        try permanentlyDeleteResult.get()
    }

    func reconcileTrash(space: Space) async throws {
        reconcileTrashCallCount += 1
        lastReconciledTrashSpace = space
        try reconcileTrashResult.get()
    }

    // MARK: - Discovery browse

    func fetchPeople(offset: UInt32, limit: UInt32) async throws -> [Person] {
        fetchPeopleCallCount += 1
        return try window(try peopleResult.get(), offset: offset, limit: limit)
    }

    func fetchPlaces(offset: UInt32, limit: UInt32) async throws -> [Place] {
        fetchPlacesCallCount += 1
        return try window(try placesResult.get(), offset: offset, limit: limit)
    }

    func fetchSubjects(offset: UInt32, limit: UInt32) async throws -> [Subject] {
        fetchSubjectsCallCount += 1
        return try window(try subjectsResult.get(), offset: offset, limit: limit)
    }

    func fetchTags(offset: UInt32, limit: UInt32) async throws -> [Tag] {
        fetchTagsCallCount += 1
        return try window(try tagsResult.get(), offset: offset, limit: limit)
    }

    func fetchAlbums(offset: UInt32, limit: UInt32) async throws -> [Album] {
        fetchLiveAlbumsCallCount += 1
        return try window(try liveAlbumsResult.get(), offset: offset, limit: limit)
    }

    func fetchAssetsFor(collection: DiscoveryCollection, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        fetchAssetsForCallCount += 1
        lastFetchAssetsForCollection = collection
        if let fetchAssetsForResult {
            return try window(try fetchAssetsForResult.get(), offset: offset, limit: limit)
        }
        return try window(assetsForCollection[collection] ?? [], offset: offset, limit: limit)
    }

    func searchAssets(keyword: String, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        searchAssetsCallCount += 1
        lastSearchKeyword = keyword
        if let searchAssetsResult {
            return try window(try searchAssetsResult.get(), offset: offset, limit: limit)
        }
        return try window(assetsForKeyword[keyword] ?? [], offset: offset, limit: limit)
    }

    func searchAssetsFiltered(keyword: String, filters: SearchFilters, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        searchAssetsFilteredCallCount += 1
        lastSearchKeyword = keyword
        lastSearchFilters = filters
        if let searchAssetsFilteredResult {
            return try window(try searchAssetsFilteredResult.get(), offset: offset, limit: limit)
        }
        return try window(assetsForKeyword[keyword] ?? [], offset: offset, limit: limit)
    }

    func fetchSearchFacets() async throws -> SearchFacets {
        fetchSearchFacetsCallCount += 1
        return try searchFacetsResult.get()
    }

    /// Shared windowing helper matching `fetchAssets`' own offset/limit
    /// slicing, reused across every discovery-browse list method above so
    /// each one honors the same paging contract the real core does.
    private func window<T>(_ all: [T], offset: UInt32, limit: UInt32) throws -> [T] {
        let start = Int(offset)
        guard start < all.count else { return [] }
        let end = min(start + Int(limit), all.count)
        return Array(all[start..<end])
    }
}
