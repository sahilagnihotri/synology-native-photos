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
    /// Local-only windowed read of `space`'s assets narrowed by the Quick
    /// Filter facets (file type, `taken_at` range, minimum rating), newest
    /// first with the same ordering as `fetchAssets`. No network; passing
    /// every facet `nil` returns exactly what `fetchAssets` returns.
    func filterAssets(space: Space, mediaKind: MediaKind?, takenAfter: Int64?, takenBefore: Int64?, minRating: UInt8?, offset: UInt32, limit: UInt32) throws -> [Asset] {
        try core.filterAssets(space: space, mediaKind: mediaKind, takenAfter: takenAfter, takenBefore: takenBefore, minRating: minRating, offset: offset, limit: limit)
    }
    /// Local-only count of `space`'s assets matching the same Quick Filter
    /// facets as `filterAssets`; equals `assetCount` when every facet is `nil`.
    func filterCount(space: Space, mediaKind: MediaKind?, takenAfter: Int64?, takenBefore: Int64?, minRating: UInt8?) throws -> UInt64 {
        try core.filterCount(space: space, mediaKind: mediaKind, takenAfter: takenAfter, takenBefore: takenBefore, minRating: minRating)
    }
    /// Local-only per-day histogram for `space` (newest day first), for the
    /// grid's date-section headers and scroll scrubber. Cheap local read, no
    /// network; counts sum to `assetCount` and line up with `fetchAssets`.
    func dateHistogram(space: Space) throws -> [DayCount] { try core.dateHistogram(space: space) }
    func fetchLocalAlbums(space: Space) throws -> [Album] { try core.fetchLocalAlbums(space: space) }
    /// Local-only read of every asset in `space` that carries a GPS coordinate
    /// (newest first), backing the Map view. A cheap local-index query like
    /// `fetchAssets`; no network. The GPS columns are populated by the crawl,
    /// so this can briefly return nothing right after an upgrade that
    /// re-crawls, until lat/lon repopulate.
    func locatedAssets(space: Space) throws -> [Asset] {
        try core.locatedAssets(space: space)
    }
    func thumbnail(space: Space, unitId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData {
        try await core.thumbnail(space: space, unitId: unitId, cacheKey: cacheKey, size: size)
    }
    func downloadOriginal(space: Space, unitId: Int64, cacheKey: String) async throws -> String {
        try await core.downloadOriginal(space: space, unitId: unitId, cacheKey: cacheKey)
    }
    func videoPlaybackSource(space: Space, asset: Asset) async throws -> VideoPlaybackSource {
        try await core.videoPlaybackSource(space: space, asset: asset)
    }
    /// Uploads an already-rendered edited JPEG as a NEW photo in the library (a
    /// dedicated Edited folder) and reindexes so it appears. NON-DESTRUCTIVE:
    /// the original asset the edit was derived from is never modified, moved,
    /// or deleted; this only ever adds a new file.
    func saveEditedPhoto(filename: String, jpeg: Data) async throws {
        try await core.saveEditedPhoto(filename: filename, jpeg: jpeg)
    }

    // MARK: - Delete + Recently Deleted (recycle bin)

    /// The everyday delete: removes `assetIds` from the library on the NAS
    /// (gone from the Synology web app and phone too) and drops the local
    /// rows on success. Recoverable from the DSM recycle bin via the Recently
    /// Deleted view, never permanent on its own.
    func deleteAssets(space: Space, assetIds: [Int64]) async throws {
        try await core.deleteAssets(space: space, assetIds: assetIds)
    }
    /// Reads the DSM recycle bin, newest first, windowed by `offset`/`limit`.
    /// A live File Station read (there is no local mirror of the recycle
    /// bin), so it needs a session and makes network calls.
    func fetchRecentlyDeleted(offset: UInt32, limit: UInt32) async throws -> [RecycleItem] {
        try await core.fetchRecentlyDeleted(offset: offset, limit: limit)
    }
    /// Moves each recycle-bin entry in `recyclePaths` back to its original
    /// library location and re-indexes so the files reappear. Reversible;
    /// no confirm needed.
    func restoreRecentlyDeleted(recyclePaths: [String]) async throws {
        try await core.restoreRecentlyDeleted(recyclePaths: recyclePaths)
    }
    /// Permanently deletes each recycle-bin entry in `recyclePaths`. The point
    /// of no return, gated behind a dedicated, always-shown confirm in the UI.
    func emptyRecentlyDeleted(recyclePaths: [String]) async throws {
        try await core.emptyRecentlyDeleted(recyclePaths: recyclePaths)
    }
    /// JPEG bytes for one recycle-bin entry, for the Recently Deleted grid.
    /// A JSON error from the NAS surfaces as a thrown `CoreError` (never bogus
    /// image bytes), which the UI treats as "show a placeholder".
    func recycleThumbnail(recyclePath: String, size: String) async throws -> Data {
        try await core.recycleThumbnail(recyclePath: recyclePath, size: size)
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
    /// SERVER-side People/Geolocation + date filter over the library, fetched
    /// live from the NAS on every page (no local index). Backs the library
    /// Quick Filter whenever a People or Geolocation facet is chosen: those are
    /// Browse.Item query params, not local-index columns, so they cannot go
    /// through `filterAssets`. Only the set params are sent; file type stays a
    /// local filter and is never forwarded here.
    func filterItemsRemote(space: Space, startTime: Int64?, endTime: Int64?, personId: Int64?, geocodingId: Int64?, offset: UInt32, limit: UInt32) async throws -> [Asset] {
        try await core.filterItemsRemote(space: space, startTime: startTime, endTime: endTime, personId: personId, geocodingId: geocodingId, offset: offset, limit: limit)
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
