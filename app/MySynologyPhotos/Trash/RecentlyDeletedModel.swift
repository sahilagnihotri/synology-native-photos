import Foundation
import PhotosCore

/// Backs the Recently Deleted view: the DSM recycle bin, read live from the
/// NAS (there is no local mirror of the recycle bin, so every load is a File
/// Station read, not a local index query).
///
/// Items are `RecycleItem`s, NOT `Asset`s: they have no server id and are
/// keyed entirely by their `recyclePath`, which is the handle every action
/// (restore, permanent delete, thumbnail) takes. Selection is therefore a set
/// of `recyclePath`s rather than the grid's index-based selection.
///
/// Two action surfaces, matching Apple's Recently Deleted:
///  - Restore (`restoreSelected`) is fully reversible and non-destructive, so
///    it needs no confirm.
///  - Delete Permanently (`requestEmpty` -> confirm -> `confirmEmpty`) is the
///    ONLY permanent-delete path in the whole app, and its strongly-worded
///    confirm is shown every single time, never suppressed by any flag.
///
/// SAFETY: `confirmEmpty` is the sole caller of `emptyRecentlyDeleted`;
/// `requestEmpty`/`cancelEmpty` never touch the core.
@MainActor
@Observable
final class RecentlyDeletedModel {
    private let client: PhotosCoreClient
    private let pageSize: UInt32
    /// Safety cap on how many recycle-bin entries a single load will pull, so
    /// a NAS that somehow keeps returning full pages can never spin this into
    /// an unbounded fetch loop.
    private let maxItems: Int

    /// The recycle-bin entries, newest first (the order the core returns).
    private(set) var items: [RecycleItem] = []
    /// True once at least one load has completed, so the view can tell "not
    /// loaded yet" (show a spinner) apart from "loaded and genuinely empty"
    /// (show the empty state).
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    /// The selected entries, by `recyclePath`. A plain set the view toggles;
    /// `selectedPaths` reads it back in display order for a deterministic
    /// argument list to the core.
    var selection: Set<String> = []

    /// Surfaced to the view when a load or action throws. Nil while there is
    /// nothing to report.
    var errorMessage: String?

    // MARK: - Permanent-delete (empty) confirm state

    /// Drives the strongly-worded "Delete Permanently?" confirm. Set true by
    /// `requestEmpty`; shown every time, never suppressed.
    var isShowingEmptyConfirm = false
    private(set) var pendingEmptyPaths: [String] = []
    var pendingEmptyCount: Int { pendingEmptyPaths.count }

    init(client: PhotosCoreClient, pageSize: UInt32 = 200, maxItems: Int = 10_000) {
        self.client = client
        self.pageSize = pageSize
        self.maxItems = maxItems
    }

    /// The current selection in display order (matching `items`), so the
    /// argument list handed to the core is deterministic rather than the
    /// selection set's arbitrary iteration order.
    var selectedPaths: [String] {
        items.map(\.recyclePath).filter { selection.contains($0) }
    }

    var selectedCount: Int { selection.count }

    // MARK: - Load

    /// (Re)loads the whole recycle bin, paging until a short page. Drops any
    /// selection whose entry is no longer present (e.g. it was restored or
    /// permanently deleted on another client since the last load).
    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var collected: [RecycleItem] = []
            var offset: UInt32 = 0
            while true {
                let page = try await client.fetchRecentlyDeleted(offset: offset, limit: pageSize)
                collected.append(contentsOf: page)
                if page.count < Int(pageSize) { break }
                if collected.count >= maxItems { break }
                offset += pageSize
            }
            items = collected
            errorMessage = nil
            selection.formIntersection(Set(items.map(\.recyclePath)))
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not load Recently Deleted."
        }
        hasLoaded = true
    }

    // MARK: - Selection

    /// Toggles one entry's membership in the selection.
    func toggle(_ recyclePath: String) {
        if selection.contains(recyclePath) {
            selection.remove(recyclePath)
        } else {
            selection.insert(recyclePath)
        }
    }

    func isSelected(_ recyclePath: String) -> Bool { selection.contains(recyclePath) }

    // MARK: - Restore (no confirm: fully reversible, non-destructive)

    /// Restores the selected entries back into the library, reloads the
    /// recycle bin so the restored rows leave it, then runs `onDone` (the
    /// library refresh) on success. A no-op on an empty selection.
    func restoreSelected(onDone: () async -> Void = {}) async {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        do {
            try await client.restoreRecentlyDeleted(recyclePaths: paths)
            selection.removeAll()
            await load()
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not restore the selected items."
        }
    }

    // MARK: - Permanent delete (gated, always confirmed)

    /// Step 1: records the selected paths and raises the strongly-worded
    /// confirm. Does NOT call the core. A no-op on an empty selection.
    func requestEmpty() {
        let paths = selectedPaths
        guard !paths.isEmpty else { return }
        pendingEmptyPaths = paths
        isShowingEmptyConfirm = true
    }

    /// Step 2: the user confirmed the permanent delete. The ONLY caller of
    /// `emptyRecentlyDeleted`. Clears the confirm, deletes, then reloads the
    /// recycle bin so the removed rows disappear.
    func confirmEmpty() async {
        let paths = pendingEmptyPaths
        isShowingEmptyConfirm = false
        pendingEmptyPaths = []
        guard !paths.isEmpty else { return }
        do {
            try await client.emptyRecentlyDeleted(recyclePaths: paths)
            selection.removeAll()
            await load()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not permanently delete the selected items."
        }
    }

    /// The user dismissed the permanent-delete confirm. Clears state; never
    /// calls the core.
    func cancelEmpty() {
        isShowingEmptyConfirm = false
        pendingEmptyPaths = []
    }
}
