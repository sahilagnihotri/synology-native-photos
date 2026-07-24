import Foundation
import PhotosCore

/// Serializes all access to the single PhotosCore instance for the app run.
/// Every method rethrows CoreError verbatim; callers map via userMessage.
actor PhotosCoreClient {
    private let core: PhotosCoreProtocol
    init(core: PhotosCoreProtocol) { self.core = core }

    func login(connection: Connection, username: String, password: String, otpCode: String?) async throws -> Session {
        try await core.login(connection: connection, username: username, password: password, otpCode: otpCode)
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
    func fetchAlbums(space: Space) throws -> [Album] { try core.fetchAlbums(space: space) }
    func thumbnail(space: Space, assetId: Int64, cacheKey: String, size: ThumbnailSize) async throws -> ThumbnailData {
        try await core.thumbnail(space: space, assetId: assetId, cacheKey: cacheKey, size: size)
    }
    func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String {
        try await core.downloadOriginal(space: space, assetId: assetId, cacheKey: cacheKey)
    }
}
