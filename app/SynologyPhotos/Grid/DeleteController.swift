import SwiftUI
import PhotosCore

/// Owns the hybrid safe-delete flows and their confirm state, kept out of any
/// SwiftUI view so the "confirm is always shown before a mutation" contract is
/// directly unit-testable against `FakePhotosCore`.
///
/// Two clearly separated destructive surfaces:
///
///  - Everyday delete (`requestDelete` -> confirm -> `confirmDelete`) moves
///    items into the app-owned Recently Deleted album. Fully reversible; NEVER
///    calls the raw destructive verb.
///  - Permanent delete (`requestPermanentDelete` -> confirm -> its own
///    `confirmPermanentDelete`) is the only path that calls
///    `permanentlyDelete`. It lives ONLY in the Recently Deleted view and its
///    confirm is shown every single time, never suppressed by any flag.
///
/// SAFETY: no method here calls a mutating core method before the matching
/// `confirm*` step, and `confirmPermanentDelete` is the sole caller of
/// `permanentlyDelete`. `requestDelete`/`cancelDelete` (and their permanent
/// twins) never touch the core at all.
@MainActor
@Observable
final class DeleteController {
    private let client: PhotosCoreClient

    // MARK: - Everyday delete-to-trash confirm state

    /// Drives the "Move to Recently Deleted?" confirm. Set true by
    /// `requestDelete`; the view binds an alert to it.
    var isShowingTrashConfirm = false
    /// The ids captured when the confirm was raised, moved on `confirmDelete`.
    /// Never acted on until the user confirms.
    private(set) var pendingTrashIds: [Int64] = []
    var pendingTrashCount: Int { pendingTrashIds.count }

    // MARK: - Permanent-delete confirm state

    /// Drives the strongly-worded "Delete Permanently?" confirm. Set true by
    /// `requestPermanentDelete`; shown every time, never suppressed.
    var isShowingPermanentConfirm = false
    private(set) var pendingPermanentIds: [Int64] = []
    var pendingPermanentCount: Int { pendingPermanentIds.count }

    /// Surfaced to the user when a mutation throws (e.g. auth expiry mid
    /// action). Nil while there is nothing to report.
    var errorMessage: String?

    init(client: PhotosCoreClient) { self.client = client }

    // MARK: - Everyday delete-to-trash

    /// Step 1: records the ids to delete and raises the confirm. Does NOT call
    /// the core. A no-op on an empty selection so an empty confirm can never
    /// appear.
    func requestDelete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        pendingTrashIds = ids
        isShowingTrashConfirm = true
    }

    /// Step 2: the user confirmed. Moves the pending ids into Recently Deleted
    /// (reversible), clears the confirm, then runs `onDone` (the caller's grid
    /// refresh) only after the move succeeds. On failure nothing is refreshed
    /// and `errorMessage` is set.
    func confirmDelete(space: Space, onDone: () async -> Void) async {
        let ids = pendingTrashIds
        isShowingTrashConfirm = false
        pendingTrashIds = []
        guard !ids.isEmpty else { return }
        do {
            try await client.deleteToTrash(space: space, assetIds: ids)
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not move items to Recently Deleted."
        }
    }

    /// The user dismissed the confirm. Clears state; never calls the core.
    func cancelDelete() {
        isShowingTrashConfirm = false
        pendingTrashIds = []
    }

    // MARK: - Restore (no confirm needed: fully reversible, non-destructive)

    /// Moves `ids` back out of Recently Deleted into the library, then runs
    /// `onDone` (the caller's trash-view refresh) on success. A no-op on an
    /// empty selection.
    func restore(space: Space, ids: [Int64], onDone: () async -> Void) async {
        guard !ids.isEmpty else { return }
        do {
            try await client.restoreFromTrash(space: space, assetIds: ids)
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not restore items."
        }
    }

    // MARK: - Permanent delete (gated, always confirmed)

    /// Step 1: records the ids and raises the strongly-worded confirm. Does
    /// NOT call the core. A no-op on an empty selection.
    func requestPermanentDelete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        pendingPermanentIds = ids
        isShowingPermanentConfirm = true
    }

    /// Step 2: the user confirmed the permanent delete. The ONLY caller of
    /// `permanentlyDelete`. Clears the confirm, deletes, then runs `onDone`
    /// on success.
    func confirmPermanentDelete(space: Space, onDone: () async -> Void) async {
        let ids = pendingPermanentIds
        isShowingPermanentConfirm = false
        pendingPermanentIds = []
        guard !ids.isEmpty else { return }
        do {
            try await client.permanentlyDelete(space: space, assetIds: ids)
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not permanently delete items."
        }
    }

    /// The user dismissed the permanent-delete confirm. Clears state; never
    /// calls the core.
    func cancelPermanentDelete() {
        isShowingPermanentConfirm = false
        pendingPermanentIds = []
    }
}

/// The everyday "move to Recently Deleted" confirm. Names the count, is honest
/// that the move is reversible, and offers a plain Cancel. The destructive
/// button routes back into `DeleteController.confirmDelete`; Cancel calls
/// `cancelDelete` so nothing is left pending.
struct DeleteConfirmModifier: ViewModifier {
    @Bindable var controller: DeleteController
    let space: Space
    let onDone: () async -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Move to Recently Deleted",
            isPresented: $controller.isShowingTrashConfirm
        ) {
            Button("Move to Recently Deleted", role: .destructive) {
                Task { await controller.confirmDelete(space: space, onDone: onDone) }
            }
            .accessibilityIdentifier("delete.confirm")
            Button("Cancel", role: .cancel) { controller.cancelDelete() }
                .accessibilityIdentifier("delete.cancel")
        } message: {
            Text(controller.pendingTrashCount == 1
                 ? "Move 1 item to Recently Deleted? You can restore it from Recently Deleted."
                 : "Move \(controller.pendingTrashCount) items to Recently Deleted? You can restore them from Recently Deleted.")
        }
    }
}

/// The gated permanent-delete confirm, shown every single time before a raw
/// delete. Deliberately blunt about irreversibility. The destructive button
/// routes into `confirmPermanentDelete` (the only path that permanently
/// deletes); Cancel calls `cancelPermanentDelete`.
struct PermanentDeleteConfirmModifier: ViewModifier {
    @Bindable var controller: DeleteController
    let space: Space
    let onDone: () async -> Void

    func body(content: Content) -> some View {
        content.alert(
            "Delete Permanently",
            isPresented: $controller.isShowingPermanentConfirm
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task { await controller.confirmPermanentDelete(space: space, onDone: onDone) }
            }
            .accessibilityIdentifier("permanentdelete.confirm")
            Button("Cancel", role: .cancel) { controller.cancelPermanentDelete() }
                .accessibilityIdentifier("permanentdelete.cancel")
        } message: {
            Text(controller.pendingPermanentCount == 1
                 ? "This permanently deletes 1 item from your Synology. This cannot be undone."
                 : "This permanently deletes \(controller.pendingPermanentCount) items from your Synology. This cannot be undone.")
        }
    }
}

extension View {
    /// Attaches the everyday delete-to-trash confirm.
    func deleteConfirm(_ controller: DeleteController, space: Space, onDone: @escaping () async -> Void) -> some View {
        modifier(DeleteConfirmModifier(controller: controller, space: space, onDone: onDone))
    }

    /// Attaches the gated permanent-delete confirm.
    func permanentDeleteConfirm(_ controller: DeleteController, space: Space, onDone: @escaping () async -> Void) -> some View {
        modifier(PermanentDeleteConfirmModifier(controller: controller, space: space, onDone: onDone))
    }
}
