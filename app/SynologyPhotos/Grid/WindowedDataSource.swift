import Foundation
import PhotosCore

/// Identity for a single grid cell: an asset's server id scoped to the space
/// it came from, so ids from Personal and Shared never collide once the grid
/// mixes data from more than one space over its lifetime.
struct AssetItemID: Hashable {
    let space: Space
    let serverId: Int64
}

/// What a `WindowedDataSource` is currently windowing: either the local
/// library index for a `Space` (the original, crawl-backed behavior), a
/// discovery-browse `DiscoveryCollection` fetched live from the NAS on
/// every page, or a live keyword `search` (no local index for either of
/// the latter two in this pass).
///
/// Kept as an internal enum rather than separate data source types so
/// the grid controller, which only ever calls the small shared surface
/// (`item(at:)`, `totalCount`, `isReady`, `loadWindow`, `pageSize`), does
/// not need to know or care which kind of source is backing it. Selecting a
/// discovery tile or typing a search query therefore reuses the exact same
/// `PhotoGridController` the Library grid uses, per the brief.
private enum FetchSource: Equatable {
    case space(Space)
    case collection(DiscoveryCollection)
    /// A live keyword search, optionally narrowed by `SearchFilters` (the
    /// confirmed start_time/end_time date range; see `models::SearchFilters`
    /// for why no other facet is wired as a real filter yet). A default
    /// `SearchFilters()` behaves exactly like the plain keyword search this
    /// case always supported.
    case search(String, SearchFilters)
    /// The library's Quick Filter: a compound, LOCAL-index filter over a
    /// space's assets by `FilterQuery` (file type, date-taken range, minimum
    /// rating). Like `.space` it is a cheap local read with an exact count, so
    /// unlike `.collection`/`.search` its count and readiness come from a real
    /// `filterCount`, not a page-size estimate. It stays a single flat section
    /// (no date-section headers or scrubber) while active.
    case filter(Space, FilterQuery)
}

/// Bridges the NSCollectionView grid to the core's windowed reads.
///
/// A 20k-100k library must never be pulled into memory or onto the main
/// thread as one shot: the grid only ever asks for the rows it can actually
/// show, and this type is the single place that turns "the grid wants row N"
/// into a bounded fetch call against either the local index
/// (`fetchAssets(space:offset:limit:)`) or, for a discovery collection, a
/// live NAS call (`fetchAssetsFor(collection:offset:limit:)`). It keeps a
/// sparse cache of the pages it has already loaded, keyed by absolute
/// index, so scrolling back over rows already seen is a dictionary lookup,
/// not a re-fetch.
///
/// `isReady` gates on crawl completion for a `Space` source: while a
/// space's crawl is still in progress, `totalCount` reflects however many
/// rows have been indexed so far, and the grid is expected to treat that as
/// a partial, still-growing library rather than the final one. A discovery
/// collection has no crawl barrier at all (it is fetched live, not
/// indexed), so `isReady` is true as soon as the first page comes back, and
/// `totalCount` grows the same way the Rust `ApiPageSource` estimates it:
/// a full page means there may be more, a short page means that was the
/// last one.
@MainActor
@Observable
final class WindowedDataSource {
    private let client: PhotosCoreClient
    private var source: FetchSource
    let pageSize: Int
    private(set) var totalCount: Int = 0
    private(set) var isReady: Bool = false

    /// The date-section geometry for the current source, or `nil` when the
    /// grid is not date-sectioned (a discovery collection or a live search,
    /// which stay a single flat section). Only a `.space` source populates
    /// this, from the core's per-day histogram read in `refreshCount`; it is
    /// cleared the moment the source switches away from a space. The grid's
    /// controller reads it to build one section per day and to map a grid
    /// `(section, item)` coordinate to the flat absolute index this data
    /// source pages by. Rebuilt on every `refreshCount`, so it tracks the
    /// space's real state across a crawl, a delete, or a manual refresh.
    private(set) var dateSections: GridDateSections?

    /// The space rows in the current window belong to, for `AssetItemID`
    /// purposes. For a `.space` source this is that space; for a
    /// `.collection` or `.search` source it is always `.personal`, since
    /// every discovery-browse collection (see
    /// `synology_api::browse::CollectionFilter`'s own scope) and the search
    /// API itself are personal-space-only.
    var space: Space {
        switch source {
        case .space(let s): return s
        case .filter(let s, _): return s
        case .collection, .search(_, _): return .personal
        }
    }

    /// Rows already fetched, keyed by their absolute index in the current
    /// source's ordering. Cleared whenever the source changes.
    private var resident: [Int: Asset] = [:]
    /// Page indices (0-based, `pageSize` wide) already requested from the
    /// core, so a page already in flight or already loaded is never
    /// re-fetched just because a second cell in the same page is queried.
    private var loadedPages: Set<Int> = []
    private var pagesInFlight: Set<Int> = []

    init(client: PhotosCoreClient, space: Space, pageSize: Int = 200) {
        self.client = client
        self.source = .space(space)
        self.pageSize = pageSize
    }

    /// Refreshes `totalCount` and `isReady` from the core. For a `.space`
    /// source this is a cheap local read only, never touching the network.
    /// For a `.collection` source there is no local count to read (no
    /// index), so this is a no-op: `totalCount`/`isReady` for a collection
    /// are instead driven entirely by `loadWindow`'s own page-size
    /// heuristic, updated as pages arrive.
    func refreshCount() async {
        switch source {
        case .space(let space):
            do {
                let count = try await client.assetCount(space: space)
                totalCount = Int(count)
                let progress = try await client.crawlProgress(space: space)
                isReady = progress.complete
                // Same DB snapshot as the count above: the histogram's counts
                // sum to `assetCount`, so `dateSections.totalCount` matches
                // `totalCount` and the grid's section geometry stays in step
                // with the flat count it pages by.
                let histogram = try await client.dateHistogram(space: space)
                dateSections = GridDateSections(histogram: histogram)
            } catch {
                totalCount = 0
                isReady = false
                dateSections = nil
            }
        case .filter(let space, let query):
            do {
                let count = try await client.filterCount(
                    space: space,
                    mediaKind: query.mediaKind,
                    takenAfter: query.takenAfter,
                    takenBefore: query.takenBefore,
                    minRating: query.minRating)
                totalCount = Int(count)
                // A filtered read is a local-index read like `fetchAssets`:
                // the count is authoritative the instant we have it, so the
                // grid is ready to page it (there is no separate crawl barrier
                // to wait on here). The filtered grid is a single flat section,
                // never date-sectioned, so its section geometry is cleared.
                isReady = true
                dateSections = nil
            } catch {
                totalCount = 0
                isReady = false
                dateSections = nil
            }
        case .collection, .search:
            break
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
            let rows: [Asset]
            switch source {
            case .space(let space):
                rows = try await client.fetchAssets(space: space, offset: UInt32(offset), limit: UInt32(limit))
            case .collection(let collection):
                rows = try await client.fetchAssetsFor(collection: collection, offset: UInt32(offset), limit: UInt32(limit))
                // No local index/crawl barrier for a discovery collection:
                // estimate totalCount/isReady the same way the Rust
                // ApiPageSource does for the initial crawl. A full page
                // means there may be more rows beyond it; a short page
                // (fewer rows than asked for) means this was the last one.
                isReady = rows.count < limit
                totalCount = max(totalCount, offset + rows.count)
            case .search(let keyword, let filters):
                rows = try await client.searchAssetsFiltered(keyword: keyword, filters: filters, offset: UInt32(offset), limit: UInt32(limit))
                // Same live-fetch, no-local-index estimate as `.collection`
                // above: a search has no crawl barrier or grand total either.
                isReady = rows.count < limit
                totalCount = max(totalCount, offset + rows.count)
            case .filter(let space, let query):
                // Like `.space`, a local read whose count/readiness are owned
                // by `refreshCount` (from `filterCount`), so this only fetches
                // the requested slice and never touches totalCount/isReady.
                rows = try await client.filterAssets(
                    space: space,
                    mediaKind: query.mediaKind,
                    takenAfter: query.takenAfter,
                    takenBefore: query.takenBefore,
                    minRating: query.minRating,
                    offset: UInt32(offset),
                    limit: UInt32(limit))
            }
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

    /// Read-only lookup of an already-resident row that NEVER schedules a
    /// page load for a missing one (unlike `item(at:)`). Used by the delete
    /// action that resolves the current selection's absolute indices to asset
    /// ids: it must only ever target rows the user can actually see (already
    /// loaded), and must never kick off a wave of page loads as a side effect
    /// of merely reading which rows are selected (e.g. after Select All on a
    /// large library).
    func residentItem(at index: Int) -> Asset? { resident[index] }

    /// Switches the active space, drops every cached row and page marker
    /// from the previous source, and re-queries count/readiness for the new
    /// one. Grid indices are meaningless across a source switch, so nothing
    /// from the old source is retained.
    func setSpace(_ newSpace: Space) async {
        source = .space(newSpace)
        resetResident()
        await refreshCount()
    }

    /// Drops every cached row and re-reads count/readiness for the CURRENT
    /// source, without switching sources. Used after a delete (or a manual
    /// Refresh) so the grid reflects the new server state: a plain page
    /// reload cannot be trusted after rows are
    /// removed, since every absolute index at or beyond the removed row shifts
    /// and the resident cache would otherwise keep serving stale entries at
    /// those indices. Callers `loadWindow` + re-apply the snapshot after this.
    func reload() async {
        resetResident()
        await refreshCount()
    }

    /// Switches to windowing one discovery-browse `collection` instead of a
    /// space's library. Same reset discipline as `setSpace`: every cached
    /// row/page marker from whatever was previously loaded is dropped, since
    /// indices are meaningless across the switch. `totalCount`/`isReady`
    /// start at zero/false and are populated by the first `loadWindow` call
    /// (there is no cheap local count to seed them with up front, unlike
    /// `setSpace`), so callers are expected to call `loadWindow` right after
    /// this, the same way `LibraryView` already does after `setSpace`.
    func setCollection(_ collection: DiscoveryCollection) async {
        source = .collection(collection)
        resetResident()
        totalCount = 0
        isReady = false
        // A discovery collection is never date-sectioned (no local histogram);
        // drop any section geometry left over from a `.space` source so the
        // grid falls back to a single flat section.
        dateSections = nil
    }

    /// Switches to windowing a live keyword `search` instead of a space's
    /// library or a discovery-browse collection, optionally narrowed by
    /// `filters` (the confirmed date range; defaults to no filter, matching
    /// the plain keyword search this method always supported). Same reset
    /// discipline as `setCollection`: every cached row/page marker from
    /// whatever was previously loaded is dropped, and `totalCount`/`isReady`
    /// start at zero/false, populated by the first `loadWindow` call the
    /// same way.
    func setSearch(_ keyword: String, filters: SearchFilters = SearchFilters(startTime: nil, endTime: nil)) async {
        source = .search(keyword, filters)
        resetResident()
        totalCount = 0
        isReady = false
        // Live search results are never date-sectioned; drop any section
        // geometry from a prior `.space` source (see `setCollection`).
        dateSections = nil
    }

    /// Switches to windowing `space`'s library narrowed by the Quick Filter
    /// `query`, instead of the plain library, a discovery collection, or a
    /// search. Same reset discipline as `setSpace`: every cached row/page
    /// marker is dropped since indices are meaningless across the switch.
    /// Unlike `setCollection`/`setSearch`, this then calls `refreshCount`
    /// because a filtered read HAS a cheap, exact local count (`filterCount`),
    /// which seeds `totalCount`/`isReady` up front and clears the date-section
    /// geometry so the filtered grid renders as a single flat section.
    /// Callers `loadWindow` + re-apply the snapshot after this, the same way
    /// `LibraryView` already does after `setSpace`.
    func setFilter(space: Space, query: FilterQuery) async {
        source = .filter(space, query)
        resetResident()
        await refreshCount()
    }

    private func resetResident() {
        resident.removeAll()
        loadedPages.removeAll()
        pagesInFlight.removeAll()
    }

    // MARK: - Page-aligned on-demand loading

    private func pageIndex(for index: Int) -> Int { index / pageSize }

    private func schedulePageLoad(containing index: Int) {
        let page = pageIndex(for: index)
        guard !loadedPages.contains(page), !pagesInFlight.contains(page) else { return }
        pagesInFlight.insert(page)
        let offset = page * pageSize
        let limit = pageSize
        let requestSource = source
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pagesInFlight.remove(page) }
            // The source may have changed while this fetch was in flight;
            // discard results that no longer belong to the active source.
            guard self.source == requestSource else { return }
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
