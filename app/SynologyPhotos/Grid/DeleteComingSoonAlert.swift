import SwiftUI

/// State for the "deletion is coming" affordance the Delete/Cmd-Delete key
/// opens. Real delete (Synology recycle-bin move + confirm) is Phase 2 and
/// not built yet; this exists so the key binding is discoverable and honest
/// about that, rather than either a silent no-op or a fake success message.
@MainActor
@Observable
final class DeleteComingSoonModel {
    var isShowingAlert = false
    /// How many items were selected when Delete was pressed, shown in the
    /// alert so the user can tell the key registered their selection even
    /// though nothing happens yet.
    var pendingCount = 0

    func requestDelete(selectedCount: Int) {
        guard selectedCount > 0 else { return }
        pendingCount = selectedCount
        isShowingAlert = true
    }
}

/// The alert itself, attached to `LibraryView`. Wording is deliberately
/// plain about the current state: deleting is not implemented yet, nothing
/// was removed, and there is a single acknowledgement button, no fake
/// "Delete"/"Move to Trash" action that would do nothing when tapped.
struct DeleteComingSoonAlertModifier: ViewModifier {
    @Bindable var model: DeleteComingSoonModel

    func body(content: Content) -> some View {
        content.alert(
            "Deleting Isn't Available Yet",
            isPresented: $model.isShowingAlert
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.pendingCount == 1
                 ? "Safe delete (recycle bin) is coming in a future update. This photo was not removed."
                 : "Safe delete (recycle bin) is coming in a future update. These \(model.pendingCount) photos were not removed.")
        }
    }
}

extension View {
    func deleteComingSoonAlert(_ model: DeleteComingSoonModel) -> some View {
        modifier(DeleteComingSoonAlertModifier(model: model))
    }
}
