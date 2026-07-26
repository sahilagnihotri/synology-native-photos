import Testing
import PhotosCore
@testable import MySynologyPhotos

@MainActor
struct CrawlProgressModelTests {
    @Test func emitsImportingTextThenCompletes() async {
        let fake = FakePhotosCore()
        fake.crawlProgressToEmit = [
            CrawlProgress(space: .personal, done: 100, total: 1000, complete: false),
            CrawlProgress(space: .personal, done: 500, total: 1000, complete: false),
        ]
        fake.crawlFinal[.personal] = CrawlProgress(space: .personal, done: 1000, total: 1000, complete: true)
        let model = CrawlProgressModel(client: PhotosCoreClient(core: fake))
        await model.startCrawl(space: .personal)
        #expect(model.isComplete == true)
        #expect(model.done == 1000)
        #expect(model.total == 1000)
        #expect(model.statusText.contains("1000"))
    }

    @Test func importingTextFormat() {
        let model = CrawlProgressModel(client: PhotosCoreClient(core: FakePhotosCore()))
        model.apply(CrawlProgress(space: .personal, done: 42, total: 900, complete: false))
        #expect(model.statusText == "Importing 42 of 900")
        #expect(model.isComplete == false)
    }

    @Test func completeShowsReadyText() {
        let model = CrawlProgressModel(client: PhotosCoreClient(core: FakePhotosCore()))
        model.apply(CrawlProgress(space: .personal, done: 900, total: 900, complete: true))
        #expect(model.isComplete == true)
        #expect(model.statusText.localizedCaseInsensitiveContains("ready") ||
                model.statusText.localizedCaseInsensitiveContains("900"))
    }

    /// A failed crawl must not leave `isComplete` true: the barrier only
    /// ever flips on an explicit `complete=true` from the core, never as a
    /// side effect of the request finishing (successfully or not).
    @Test func failedCrawlLeavesNotComplete() async {
        let fake = FakePhotosCore()
        fake.crawlSpaceResult = .failure(.Network(message: "offline"))
        let model = CrawlProgressModel(client: PhotosCoreClient(core: fake))
        await model.startCrawl(space: .personal)
        #expect(model.isComplete == false)
    }

    /// The failure message shown to the user comes from `CoreError.userMessage`
    /// (already scrubbed of anything sensitive), never a raw internal error,
    /// so the UI can surface it directly.
    @Test func failedCrawlRecordsUserFacingMessage() async {
        let fake = FakePhotosCore()
        fake.crawlSpaceResult = .failure(.Network(message: "offline"))
        let model = CrawlProgressModel(client: PhotosCoreClient(core: fake))
        await model.startCrawl(space: .personal)
        #expect(model.failure == CoreError.Network(message: "offline").userMessage)
    }

    /// A retry (another `startCrawl`) that succeeds must clear the previous
    /// failure: the failed state is never sticky once the crawl recovers.
    @Test func successfulRetryClearsPriorFailure() async {
        let fake = FakePhotosCore()
        fake.crawlSpaceResult = .failure(.Network(message: "offline"))
        let model = CrawlProgressModel(client: PhotosCoreClient(core: fake))
        await model.startCrawl(space: .personal)
        #expect(model.failure != nil)

        fake.crawlSpaceResult = nil
        fake.crawlFinal[.personal] = CrawlProgress(space: .personal, done: 10, total: 10, complete: true)
        await model.startCrawl(space: .personal)
        #expect(model.failure == nil)
        #expect(model.isComplete == true)
    }

    /// `refresh` picks up the core's current barrier state (e.g. a crawl
    /// that already finished in an earlier session) without needing to
    /// re-run `startCrawl`.
    @Test func refreshReadsCurrentBarrierState() async {
        let fake = FakePhotosCore()
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 250, total: 250, complete: true)
        let model = CrawlProgressModel(client: PhotosCoreClient(core: fake))
        await model.refresh(space: .personal)
        #expect(model.isComplete == true)
        #expect(model.done == 250)
        #expect(model.total == 250)
    }
}
