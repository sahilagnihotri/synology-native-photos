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
    /// crawl leaves `isComplete` false: the barrier only ever flips to true
    /// when the core itself reports completion, never on the client side.
    func startCrawl(space: Space) async {
        let observer = Observer { [weak self] progress in
            Task { @MainActor in self?.apply(progress) }
        }
        do {
            let final = try await client.crawlSpace(space: space, observer: observer)
            apply(final)
        } catch {
            isComplete = false
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
        } catch {
            isComplete = false
        }
    }
}
