import Foundation
import PhotosCore

/// The subset of the generated `PhotosCore` object that the rest of the app
/// codes against. Method names and signatures mirror interface contract
/// section 2.5 exactly, so the real UniFFI-generated `PhotosCore` conforms
/// without any adaptation once the bindings are regenerated with the full
/// method surface.
///
/// Every consumer above the FFI boundary (view models, controllers, tests)
/// should depend on `PhotosCoreProtocol`, never on the concrete `PhotosCore`
/// type, so a `FakePhotosCore` can stand in during development and testing.
public protocol PhotosCoreProtocol: AnyObject, Sendable {
    /// Log in. `otpCode` is `nil` on first attempt; if the core throws
    /// `CoreError.otpRequired`, the caller re-invokes with the OTP supplied.
    func login(
        connection: Connection,
        username: String,
        password: String,
        otpCode: String?
    ) async throws -> Session

    /// Restore a prior session (SID from Keychain) without re-entering
    /// credentials. Validates by a cheap authed call and returns the state.
    func restoreSession(connection: Connection, session: Session) async throws -> SessionState

    /// Clean teardown: server logout, drop in-memory client, clear
    /// per-account local cache. Idempotent.
    func signOut() async throws

    /// SYNO.API.Info query=all. Pins versions used by later calls.
    func probeCapabilities() async throws -> [ApiCapability]

    /// Resumable initial crawl for one space. Streams progress via the
    /// observer and returns the final `CrawlProgress` with `complete == true`.
    func crawlSpace(space: Space, observer: FfiCrawlObserver) async throws -> CrawlProgress

    /// Delta reconciliation by server (id, version). Call after the initial
    /// crawl for the space is complete.
    func reconcileDelta(space: Space) async throws -> CrawlProgress

    /// Read the persisted barrier/progress without doing network work.
    func crawlProgress(space: Space) throws -> CrawlProgress

    /// Windowed slice for the grid, newest-first. Local DB only, no network.
    func fetchAssets(space: Space, offset: UInt32, limit: UInt32) throws -> [Asset]

    /// Total local asset count for a space.
    func assetCount(space: Space) throws -> UInt64

    /// Local album list for a space.
    func fetchAlbums(space: Space) throws -> [Album]

    /// Fetch a thumbnail. Returns the cached path plus bytes.
    func thumbnail(
        space: Space,
        assetId: Int64,
        cacheKey: String,
        size: ThumbnailSize
    ) async throws -> ThumbnailData

    /// Download the original to a temp file and return its absolute path.
    /// Read-only; never mutates the NAS.
    func downloadOriginal(space: Space, assetId: Int64, cacheKey: String) async throws -> String
}

/// The real generated object conforms once the xcframework carries the full
/// method surface (Task 38 regenerates `bindings/PhotosCore.swift`). Until
/// then this extension will not compile, which is expected: the app and its
/// tests build today against `FakePhotosCore`.
extension PhotosCore: PhotosCoreProtocol {}
