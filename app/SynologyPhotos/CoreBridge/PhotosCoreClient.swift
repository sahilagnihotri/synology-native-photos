import Foundation
import PhotosCore

/// Serializes all access to the single PhotosCore instance for the app run.
/// Every method rethrows CoreError verbatim; callers map via userMessage.
actor PhotosCoreClient {
    private let core: PhotosCoreProtocol
    init(core: PhotosCoreProtocol) { self.core = core }

    func login(connection: Connection, username: String, password: String, otpCode: String?, deviceToken: String?) async throws -> Session {
        try await core.login(connection: connection, username: username, password: password, otpCode: otpCode, deviceToken: deviceToken)
    }
    func fetchCertificate(host: String) async throws -> CertInfo {
        try await core.fetchCertificate(host: host)
    }
    func restoreSession(connection: Connection, session: Session) async throws -> SessionState {
        try await core.restoreSession(connection: connection, session: session)
    }
    func signOut() async throws { try await core.signOut() }
    func probeCapabilities() async throws -> [ApiCapability] { try await core.probeCapabilities() }
    func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress {
        try await core.crawlSpace(space: space, observer: observer)
    }
    func reconcileDelta(space: Space) async throws -> CrawlProgress { try await core.reconcileDelta(space: space) }
    func crawlProgress(space: Space) throws -> CrawlProgress { try core.crawlProgress(space: space) }
    func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
        try core.fetchAssets(space: space, offset: offset, limit: limit)
    }
    func assetCount(space: Space) throws -> UInt64 { try core.assetCount(space: space) }
    func fetchLocalAlbums(space: Space) throws -> [Album] { try core.fetchLocalAlbums(space: space) }
    func thumbnail(space: Space, unitId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData {
        try await core.thumbnail(space: space, unitId: unitId, cacheKey: cacheKey, size: size)
    }
    func downloadOriginal(space: Space, unitId: Int64, cacheKey: String) async throws -> String {
        try await core.downloadOriginal(space: space, unitId: unitId, cacheKey: cacheKey)
    }
    func videoPlaybackSource(space: Space, asset: Asset) async throws -> VideoPlaybackSource {
        try await core.videoPlaybackSource(space: space, asset: asset)
    }

    // MARK: - Trash (hybrid safe-delete)

    /// Resolves (creating if needed) the app-owned Recently Deleted album.
    /// Not called on the everyday path (the core's own delete/reconcile
    /// manage the album), exposed for completeness and future admin use.
    func ensureTrashAlbum(space: Space) async throws -> Album {
        try await core.ensureTrashAlbum(space: space)
    }
    /// Everyday delete: moves `assetIds` into the Recently Deleted album,
    /// fully reversible. NEVER calls the raw destructive verb.
    func deleteToTrash(space: Space, assetIds: [Int64]) async throws {
        try await core.deleteToTrash(space: space, assetIds: assetIds)
    }
    /// Moves `assetIds` back out of Recently Deleted into the library.
    func restoreFromTrash(space: Space, assetIds: [Int64]) async throws {
        try await core.restoreFromTrash(space: space, assetIds: assetIds)
    }
    /// Windowed local read of the Recently Deleted album (sync, no network),
    /// mirroring `fetchAssets`'s own local-read discipline.
    func fetchTrash(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset] {
        try core.fetchTrash(space: space, offset: offset, limit: limit)
    }
    /// Local count of trashed items (sync, no network), mirroring `assetCount`.
    func trashCount(space: Space) throws -> UInt32 {
        try core.trashCount(space: space)
    }
    /// The only path that calls the raw destructive verb. Gated behind a
    /// dedicated, always-shown confirm in the UI; never reachable from the
    /// everyday delete flow.
    func permanentlyDelete(space: Space, assetIds: [Int64]) async throws {
        try await core.permanentlyDelete(space: space, assetIds: assetIds)
    }
    /// Re-derives local trash flags from the album's real membership, so a
    /// restore done on another Synology client is reflected here.
    func reconcileTrash(space: Space) async throws {
        try await core.reconcileTrash(space: space)
    }

    // MARK: - Discovery browse

    func fetchPeople(offset: UInt32, limit: UInt32) async throws -> [Person] {
        try await core.fetchPeople(offset: offset, limit: limit)
    }
    func fetchPlaces(offset: UInt32, limit: UInt32) async throws -> [Place] {
        try await core.fetchPlaces(offset: offset, limit: limit)
    }
    func fetchSubjects(offset: UInt32, limit: UInt32) async throws -> [Subject] {
        try await core.fetchSubjects(offset: offset, limit: limit)
    }
    func fetchTags(offset: UInt32, limit: UInt32) async throws -> [Tag] {
        try await core.fetchTags(offset: offset, limit: limit)
    }
    func fetchAlbums(offset: UInt32, limit: UInt32) async throws -> [Album] {
        try await core.fetchAlbums(offset: offset, limit: limit)
    }
    func fetchAssetsFor(collection: DiscoveryCollection, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        try await core.fetchAssetsFor(collection: collection, offset: offset, limit: limit)
    }
    func searchAssets(keyword: String, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        try await core.searchAssets(keyword: keyword, offset: offset, limit: limit)
    }
    func searchAssetsFiltered(keyword: String, filters: SearchFilters, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        try await core.searchAssetsFiltered(keyword: keyword, filters: filters, offset: offset, limit: limit)
    }
    func fetchSearchFacets() async throws -> SearchFacets {
        try await core.fetchSearchFacets()
    }
}
