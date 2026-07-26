import SwiftUI
import PhotosCore

/// Owns the everyday delete flow and its confirm state, kept out of any
/// SwiftUI view so the "confirm is always shown before a mutation" contract
/// is directly unit-testable against `FakePhotosCore`.
///
/// The everyday delete (`requestDelete` -> confirm -> `confirmDelete`) is a
/// REAL delete: it removes the assets from the Synology library (gone from
/// the web app and phone too) and drops the local rows on success. The items
/// land in the DSM recycle bin and can be restored from the Recently Deleted
/// view; nothing here is permanent. Permanent deletion lives ONLY in the
/// Recently Deleted view (`RecentlyDeletedModel`), keyed by recycle path, and
/// is never reachable from this everyday flow.
///
/// SAFETY: no method here calls `deleteAssets` before the matching
/// `confirmDelete` step. `requestDelete`/`cancelDelete` never touch the core.
@MainActor
@Observable
final class DeleteController {
    private let client: PhotosCoreClient

    // MARK: - Everyday delete confirm state

    /// Drives the "Delete Photo(s)?" confirm. Set true by `requestDelete`;
    /// the view binds an alert to it.
    var isShowingDeleteConfirm = false
    /// The ids captured when the confirm was raised, deleted on
    /// `confirmDelete`. Never acted on until the user confirms.
    private(set) var pendingDeleteIds: [Int64] = []
    var pendingDeleteCount: Int { pendingDeleteIds.count }
    /// The filenames captured alongside `pendingDeleteIds`, index-aligned to
    /// them, so a confirmed delete can remember which files to look for in
    /// the recycle bin if the user immediately hits Cmd-Z to undo. Empty when
    /// the caller did not supply names (nothing to undo in that case).
    private(set) var pendingDeleteFilenames: [String] = []

    /// The filenames of the most recent SUCCESSFUL delete, kept so a single
    /// Cmd-Z can restore them from the recycle bin. Overwritten by the next
    /// successful delete and cleared once an undo runs, so only ever the
    /// single most-recent delete is undoable (matching Apple Photos).
    private(set) var lastDeletedFilenames: [String] = []
    /// The asset ids of the most recent SUCCESSFUL delete. Kept so a caller can
    /// reconcile an in-memory view (e.g. a map-cluster grid backed by a fixed
    /// asset set) against exactly what was just removed, without re-querying.
    /// Overwritten by the next successful delete, same lifetime as
    /// `lastDeletedFilenames`.
    private(set) var lastDeletedIds: [Int64] = []
    /// Whether there is a just-deleted set the next Cmd-Z can bring back.
    var canUndoDelete: Bool { !lastDeletedFilenames.isEmpty }

    /// Surfaced to the user when the delete throws (e.g. auth expiry mid
    /// action). Nil while there is nothing to report.
    var errorMessage: String?

    init(client: PhotosCoreClient) { self.client = client }

    /// Step 1: records the ids to delete and raises the confirm. Does NOT
    /// call the core. A no-op on an empty selection so an empty confirm can
    /// never appear. Shared verbatim by the grid and the full-photo detail
    /// viewer: both resolve their target to asset ids and call this.
    ///
    /// `filenames` (index-aligned to `ids`) is optional so existing call
    /// sites keep compiling; when supplied it is what a later Cmd-Z undo
    /// matches against the recycle bin. Undo is simply unavailable when it is
    /// omitted.
    func requestDelete(ids: [Int64], filenames: [String] = []) {
        guard !ids.isEmpty else { return }
        pendingDeleteIds = ids
        pendingDeleteFilenames = filenames
        isShowingDeleteConfirm = true
    }

    /// Step 2: the user confirmed. Deletes the pending ids from the library
    /// (recoverable via the recycle bin), clears the confirm, then runs
    /// `onDone` (the caller's grid refresh / viewer close) only after the
    /// delete succeeds. On failure nothing is refreshed and `errorMessage`
    /// is set. On success the captured filenames become the pending undo,
    /// replacing any earlier one.
    func confirmDelete(space: Space, onDone: () async -> Void) async {
        let ids = pendingDeleteIds
        let filenames = pendingDeleteFilenames
        isShowingDeleteConfirm = false
        pendingDeleteIds = []
        pendingDeleteFilenames = []
        guard !ids.isEmpty else { return }
        do {
            try await client.deleteAssets(space: space, assetIds: ids)
            lastDeletedFilenames = filenames
            lastDeletedIds = ids
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not delete the selected items."
        }
    }

    /// The user dismissed the confirm. Clears state; never calls the core.
    func cancelDelete() {
        isShowingDeleteConfirm = false
        pendingDeleteIds = []
        pendingDeleteFilenames = []
    }

    // MARK: - Undo the last delete (best-effort, via the recycle bin)

    /// Brings back the most recently deleted set (Cmd-Z): reads the recycle
    /// bin, finds the newest entries matching the remembered filenames, and
    /// restores exactly those. A safe no-op when there is nothing to undo or
    /// nothing in the bin matches (e.g. the entries were restored or purged
    /// elsewhere). Runs `onDone` (the caller's library refresh) only after a
    /// restore actually happened. The pending undo is cleared on success and
    /// on a no-match, but kept on a thrown error so the user can retry.
    func undoLastDelete(onDone: () async -> Void) async {
        let filenames = lastDeletedFilenames
        guard !filenames.isEmpty else { return }
        do {
            // The just-deleted entries are the newest in the bin, so the
            // first page more than covers them; a little headroom over the
            // deleted count guards against unrelated concurrent deletes
            // pushing them down slightly.
            let fetchLimit = UInt32(max(filenames.count * 2, 200))
            let recycled = try await client.fetchRecentlyDeleted(offset: 0, limit: fetchLimit)
            let paths = Self.recyclePathsToRestore(forFilenames: filenames, in: recycled)
            guard !paths.isEmpty else {
                lastDeletedFilenames = []
                return
            }
            try await client.restoreRecentlyDeleted(recyclePaths: paths)
            lastDeletedFilenames = []
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not undo the last delete."
        }
    }

    /// Pure matcher (kept static so it is directly unit-testable): given the
    /// filenames of the last delete and the current recycle-bin contents,
    /// returns the recycle paths to restore. For each just-deleted filename
    /// it picks the newest matching entry by `deletedAt`; when the same
    /// filename was deleted N times, the N newest DISTINCT matching entries
    /// are claimed rather than the same path N times. Result order follows
    /// the delete's own filename order for determinism.
    static func recyclePathsToRestore(forFilenames filenames: [String], in items: [RecycleItem]) -> [String] {
        var byName: [String: [RecycleItem]] = [:]
        for item in items {
            byName[item.filename, default: []].append(item)
        }
        for name in byName.keys {
            byName[name]?.sort { $0.deletedAt > $1.deletedAt }
        }
        var consumed: [String: Int] = [:]
        var paths: [String] = []
        for name in filenames {
            let candidates = byName[name] ?? []
            let index = consumed[name, default: 0]
            guard index < candidates.count else { continue }
            paths.append(candidates[index].recyclePath)
            consumed[name] = index + 1
        }
        return paths
    }
}

/// The everyday delete confirm. Names the count, is honest that the items go
/// to the Synology recycle bin and can be restored, and offers a plain
/// Cancel. The destructive button routes back into
/// `DeleteController.confirmDelete`; Cancel calls `cancelDelete` so nothing
/// is left pending.
struct DeleteConfirmModifier: ViewModifier {
    @Bindable var controller: DeleteController
    let space: Space
    let onDone: () async -> Void

    func body(content: Content) -> some View {
        content.alert(
            controller.pendingDeleteCount == 1 ? "Delete Photo" : "Delete Photos",
            isPresented: $controller.isShowingDeleteConfirm
        ) {
            // Delete is the alert's default action so pressing Return/Enter
            // confirms the delete (the user explicitly wants Enter to
            // confirm). The Cancel button keeps its `.cancel` role, so
            // Escape still dismisses without deleting.
            Button("Delete", role: .destructive) {
                Task { await controller.confirmDelete(space: space, onDone: onDone) }
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("delete.confirm")
            Button("Cancel", role: .cancel) { controller.cancelDelete() }
                .accessibilityIdentifier("delete.cancel")
        } message: {
            Text(controller.pendingDeleteCount == 1
                 ? "Delete 1 item? It moves to your Synology recycle bin and can be restored."
                 : "Delete \(controller.pendingDeleteCount) items? They move to your Synology recycle bin and can be restored.")
        }
    }
}

extension View {
    /// Attaches the everyday delete confirm.
    func deleteConfirm(_ controller: DeleteController, space: Space, onDone: @escaping () async -> Void) -> some View {
        modifier(DeleteConfirmModifier(controller: controller, space: space, onDone: onDone))
    }
}
