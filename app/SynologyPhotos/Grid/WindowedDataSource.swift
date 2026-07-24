import Foundation
import PhotosCore

/// Identity for a single grid cell: an asset's server id scoped to the space
/// it came from, so ids from Personal and Shared never collide once the grid
/// mixes data from more than one space over its lifetime.
struct AssetItemID: Hashable {
    let space: Space
    let serverId: Int64
}

/// Bridges the NSCollectionView grid to the core's windowed reads.
///
/// A 20k-100k library must never be pulled into memory or onto the main
/// thread as one shot: the grid only ever asks for the rows it can actually
/// show, and this type is the single place that turns "the grid wants row N"
/// into a bounded `fetchAssets(space:offset:limit:)` call against the local
/// index. It keeps a sparse cache of the pages it has already loaded, keyed
/// by absolute index, so scrolling back over rows already seen is a
/// dictionary lookup, not a re-fetch.
///
/// `isReady` gates on crawl completion: while a space's crawl is still in
/// progress, `totalCount` reflects however many rows have been indexed so
/// far, and the grid is expected to treat that as a partial, still-growing
/// library rather than the final one.
@MainActor
@Observable
final class WindowedDataSource {
    private let client: PhotosCoreClient
    private(set) var space: Space
    let pageSize: Int
    private(set) var totalCount: Int = 0
    private(set) var isReady: Bool = false

    /// Rows already fetched, keyed by their absolute index in the current
    /// space's ordering. Cleared whenever the space changes.
    private var resident: [Int: Asset] = [:]
    /// Page indices (0-based, `pageSize` wide) already requested from the
    /// core, so a page already in flight or already loaded is never
    /// re-fetched just because a second cell in the same page is queried.
    private var loadedPages: Set<Int> = []
    private var pagesInFlight: Set<Int> = []

    init(client: PhotosCoreClient, space: Space, pageSize: Int = 200) {
        self.client = client
        self.space = space
        self.pageSize = pageSize
    }

    /// Refreshes `totalCount` and `isReady` from the core. Cheap local reads
    /// only; never touches the network.
    func refreshCount() async {
        do {
            let count = try await client.assetCount(space: space)
            totalCount = Int(count)
            let progress = try await client.crawlProgress(space: space)
            isReady = progress.complete
        } catch {
            totalCount = 0
            isReady = false
        }
    }

    /// Fetches exactly the requested slice from the core and merges it into
    /// the resident cache. Callers (tests, or the grid's own prefetch logic)
    /// can call this directly for a precise window; `item(at:)` uses the
    /// page-aligned variant below for on-demand loading as the user scrolls.
    @discardableResult
    func loadWindow(offset: Int, limit: Int) async -> [Asset] {
        guard offset >= 0, limit > 0 else { return [] }
        do {
            let rows = try await client.fetchAssets(space: space, offset: UInt32(offset), limit: UInt32(limit))
            for (i, asset) in rows.enumerated() { resident[offset + i] = asset }
            markPagesLoaded(coveringOffset: offset, limit: rows.count)
            return rows
        } catch {
            return []
        }
    }

    /// Returns the asset already resident at `index`, or `nil` if it has not
    /// been loaded yet. When `nil` is returned for an in-range index, this
    /// also schedules a background load of the page containing `index` (a
    /// no-op if that page is already loaded or already in flight), so a
    /// follow-up call after the fetch completes will resolve. The grid is
    /// expected to reload the cell once `resident` changes.
    func item(at index: Int) -> Asset? {
        if let cached = resident[index] { return cached }
        guard index >= 0, index < totalCount else { return nil }
        schedulePageLoad(containing: index)
        return nil
    }

    /// Switches the active space, drops every cached row and page marker
    /// from the previous space, and re-queries count/readiness for the new
    /// one. Grid indices are meaningless across a space switch, so nothing
    /// from the old space is retained.
    func setSpace(_ newSpace: Space) async {
        space = newSpace
        resident.removeAll()
        loadedPages.removeAll()
        pagesInFlight.removeAll()
        await refreshCount()
    }

    // MARK: - Page-aligned on-demand loading

    private func pageIndex(for index: Int) -> Int { index / pageSize }

    private func schedulePageLoad(containing index: Int) {
        let page = pageIndex(for: index)
        guard !loadedPages.contains(page), !pagesInFlight.contains(page) else { return }
        pagesInFlight.insert(page)
        let offset = page * pageSize
        let limit = pageSize
        let requestSpace = space
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pagesInFlight.remove(page) }
            // The space may have changed while this fetch was in flight;
            // discard results that no longer belong to the active space.
            guard self.space == requestSpace else { return }
            _ = await self.loadWindow(offset: offset, limit: limit)
        }
    }

    private func markPagesLoaded(coveringOffset offset: Int, limit: Int) {
        guard limit > 0 else { return }
        let firstPage = pageIndex(for: offset)
        let lastPage = pageIndex(for: offset + limit - 1)
        for page in firstPage...lastPage { loadedPages.insert(page) }
    }
}
