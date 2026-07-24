import Foundation
import PhotosCore

/// Observes the initial crawl and surfaces "Importing N of M". Only reports
/// ready when the core flips the initial_crawl_complete barrier
/// (complete=true); the grid must not treat a partial crawl as the full
/// library.
@MainActor
@Observable
final class CrawlProgressModel {
    private let client: PhotosCoreClient
    var done: UInt64 = 0
    var total: UInt64 = 0
    var isComplete: Bool = false

    /// Set when the most recent `startCrawl`/`refresh` call failed. Orthogonal
    /// to `isComplete`: a failure never flips the barrier, it only gives the
    /// UI something to show instead of spinning forever on a dead crawl.
    /// Cleared at the start of the next attempt.
    var failure: String?

    init(client: PhotosCoreClient) { self.client = client }

    /// User-facing status text. Never claims readiness unless `isComplete`
    /// is actually true, since that is the only signal the grid is allowed
    /// to treat as "the full library is here".
    var statusText: String {
        if isComplete { return "Ready. \(done) items." }
        if total == 0 { return "Importing..." }
        return "Importing \(done) of \(total)"
    }

    /// Applies a single progress tick (or a final result) from the core.
    /// Safe to call from `startCrawl`'s observer bridge or directly in tests.
    func apply(_ progress: CrawlProgress) {
        done = progress.done
        total = progress.total
        isComplete = progress.complete
    }

    /// Callback bridge from Rust: the FFI layer calls `onProgress` off the
    /// main actor, so each tick is forwarded onto the main actor before
    /// touching `apply`.
    final class Observer: FfiCrawlObserver, @unchecked Sendable {
        private let sink: @Sendable (CrawlProgress) -> Void
        init(sink: @escaping @Sendable (CrawlProgress) -> Void) { self.sink = sink }
        func onProgress(progress: CrawlProgress) { sink(progress) }
    }

    /// Runs the initial crawl for `space`, applying every progress tick as
    /// it arrives and the final result once the crawl finishes. A failed
    /// crawl leaves `isComplete` false and records a user-facing `failure`
    /// message instead: the barrier only ever flips to true when the core
    /// itself reports completion, never on the client side.
    func startCrawl(space: Space) async {
        failure = nil
        let observer = Observer { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        do {
            let final = try await client.crawlSpace(space: space, observer: observer)
            apply(final)
        } catch {
            isComplete = false
            failure = Self.message(for: error)
        }
    }

    /// Refreshes `done`/`total`/`isComplete` from the core's current
    /// snapshot without starting a new crawl. Used to pick up the barrier's
    /// state on launch (e.g. a previous session already finished crawling,
    /// or a background reconcile is updating counts) without re-running the
    /// full crawl.
    func refresh(space: Space) async {
        do {
            let progress = try await client.crawlProgress(space: space)
            apply(progress)
            failure = nil
        } catch {
            isComplete = false
            failure = Self.message(for: error)
        }
    }

    /// User-facing message for a thrown error. Uses `CoreError.userMessage`
    /// when the error crossed the FFI boundary as one (already scrubbed of
    /// anything sensitive, see `CoreError+Swift.swift`); falls back to a
    /// generic message for anything else so nothing internal ever reaches
    /// the screen.
    private static func message(for error: Error) -> String {
        if let coreError = error as? CoreError { return coreError.userMessage }
        return "Could not load your library."
    }
}
