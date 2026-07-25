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

    /// Surfaced to the user when the delete throws (e.g. auth expiry mid
    /// action). Nil while there is nothing to report.
    var errorMessage: String?

    init(client: PhotosCoreClient) { self.client = client }

    /// Step 1: records the ids to delete and raises the confirm. Does NOT
    /// call the core. A no-op on an empty selection so an empty confirm can
    /// never appear. Shared verbatim by the grid and the full-photo detail
    /// viewer: both resolve their target to asset ids and call this.
    func requestDelete(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        pendingDeleteIds = ids
        isShowingDeleteConfirm = true
    }

    /// Step 2: the user confirmed. Deletes the pending ids from the library
    /// (recoverable via the recycle bin), clears the confirm, then runs
    /// `onDone` (the caller's grid refresh / viewer close) only after the
    /// delete succeeds. On failure nothing is refreshed and `errorMessage`
    /// is set.
    func confirmDelete(space: Space, onDone: () async -> Void) async {
        let ids = pendingDeleteIds
        isShowingDeleteConfirm = false
        pendingDeleteIds = []
        guard !ids.isEmpty else { return }
        do {
            try await client.deleteAssets(space: space, assetIds: ids)
            await onDone()
        } catch {
            errorMessage = (error as? CoreError)?.userMessage ?? "Could not delete the selected items."
        }
    }

    /// The user dismissed the confirm. Clears state; never calls the core.
    func cancelDelete() {
        isShowingDeleteConfirm = false
        pendingDeleteIds = []
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
            Button("Delete", role: .destructive) {
                Task { await controller.confirmDelete(space: space, onDone: onDone) }
            }
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
