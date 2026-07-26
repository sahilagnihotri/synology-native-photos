import SwiftUI
import AppKit
import PhotosCore

/// The Recently Deleted screen: a simple grid of the DSM recycle bin's
/// contents (`RecycleItem`s, keyed by `recyclePath`), each cell showing an
/// async thumbnail, the filename, and the date it was deleted.
///
/// This is deliberately NOT the `PhotoGridController`/`NSCollectionView` grid
/// the library uses: recycle-bin entries are not `Asset`s (no server id, no
/// local index), so they get their own lightweight `LazyVGrid`. Its own
/// action bar carries Restore (reversible) and the gated Delete Permanently,
/// the only permanent-delete surface in the app.
struct RecentlyDeletedView: View {
    @Bindable var model: RecentlyDeletedModel
    let client: PhotosCoreClient
    /// Refreshes the library after a restore so the returned items reappear
    /// in the main grid without the user having to trigger it themselves.
    let onLibraryShouldRefresh: () async -> Void

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(spacing: 8) {
            actionBar
            content
        }
        .task {
            // Load once on first appearance; re-entering the view reuses what
            // is already loaded (the explicit Refresh button re-fetches).
            if !model.hasLoaded { await model.load() }
        }
        .emptyRecycleBinConfirm(model)
        .alert(
            "Recently Deleted",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - Action bar

    @ViewBuilder
    private var actionBar: some View {
        HStack(spacing: 12) {
            if model.selectedCount > 0 {
                Text("\(model.selectedCount) selected")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("recentlydeleted.selectioncount")
                Button {
                    Task { await model.restoreSelected { await onLibraryShouldRefresh() } }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("recentlydeleted.restore")
                Button(role: .destructive) { model.requestEmpty() } label: {
                    Label("Delete Permanently", systemImage: "trash.slash")
                }
                .accessibilityIdentifier("recentlydeleted.deletepermanently")
            }
            Spacer()
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .accessibilityIdentifier("recentlydeleted.refresh")
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            ProgressView("Loading...")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("recentlydeleted.progressview")
        } else if model.items.isEmpty {
            RecentlyDeletedEmptyView()
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(model.items, id: \.recyclePath) { item in
                        RecycleItemCell(
                            item: item,
                            isSelected: model.isSelected(item.recyclePath),
                            client: client
                        )
                        .onTapGesture { model.toggle(item.recyclePath) }
                        // Right-click a recycle-bin entry for its two actions,
                        // routed through the same model methods the action bar
                        // uses. Selects the entry first if it is not already
                        // selected, so the action targets what was clicked.
                        .contextMenu {
                            Button {
                                if !model.isSelected(item.recyclePath) { model.toggle(item.recyclePath) }
                                Task { await model.restoreSelected { await onLibraryShouldRefresh() } }
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            Button(role: .destructive) {
                                if !model.isSelected(item.recyclePath) { model.toggle(item.recyclePath) }
                                model.requestEmpty()
                            } label: {
                                Label("Delete Permanently", systemImage: "trash.slash")
                            }
                        }
                    }
                }
                .padding(12)
            }
            .accessibilityIdentifier("recentlydeleted.grid")
        }
    }
}

/// One recycle-bin entry: an async thumbnail (with a graceful placeholder
/// while loading or on error), the filename, and the date it was deleted.
/// Loads its thumbnail through `recycleThumbnail(recyclePath:size:)`, keyed
/// on `recyclePath` so a reused cell reloads for its new entry.
struct RecycleItemCell: View {
    let item: RecycleItem
    let isSelected: Bool
    let client: PhotosCoreClient

    @State private var image: NSImage?
    @State private var didFail = false

    private static let side: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                thumbnail
                if item.mediaKind == .video {
                    playBadge
                }
            }
            .frame(width: Self.side, height: Self.side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Color.accentColor)
                        .padding(6)
                }
            }

            Text(item.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.side, alignment: .leading)
            Text(Self.deletedDateText(item.deletedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: Self.side, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("recentlydeleted.cell")
        .task(id: item.recyclePath) { await loadThumbnail() }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Self.side, height: Self.side)
        } else if didFail {
            Image(systemName: item.mediaKind == .video ? "video" : "photo")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private var playBadge: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.5), in: Circle())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(6)
    }

    private func loadThumbnail() async {
        didFail = false
        image = nil
        do {
            let data = try await client.recycleThumbnail(recyclePath: item.recyclePath, size: "medium")
            if let decoded = NSImage(data: data) {
                image = decoded
            } else {
                didFail = true
            }
        } catch {
            didFail = true
        }
    }

    /// Formats a unix-seconds `deletedAt` as an abbreviated local date, e.g.
    /// "Jul 20, 2026".
    static func deletedDateText(_ deletedAt: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(deletedAt))
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The gated permanent-delete confirm for the recycle bin, shown every single
/// time before an unrecoverable delete. Deliberately blunt about
/// irreversibility. The destructive button routes into
/// `RecentlyDeletedModel.confirmEmpty` (the only path that permanently
/// deletes); Cancel calls `cancelEmpty`.
struct EmptyRecycleBinConfirmModifier: ViewModifier {
    @Bindable var model: RecentlyDeletedModel

    func body(content: Content) -> some View {
        content.alert(
            "Delete Permanently",
            isPresented: $model.isShowingEmptyConfirm
        ) {
            Button("Delete Permanently", role: .destructive) {
                Task { await model.confirmEmpty() }
            }
            .accessibilityIdentifier("recentlydeleted.empty.confirm")
            Button("Cancel", role: .cancel) { model.cancelEmpty() }
                .accessibilityIdentifier("recentlydeleted.empty.cancel")
        } message: {
            Text(model.pendingEmptyCount == 1
                 ? "This permanently deletes 1 item. This cannot be undone."
                 : "This permanently deletes \(model.pendingEmptyCount) items. This cannot be undone.")
        }
    }
}

extension View {
    /// Attaches the gated permanent-delete (empty recycle bin) confirm.
    func emptyRecycleBinConfirm(_ model: RecentlyDeletedModel) -> some View {
        modifier(EmptyRecycleBinConfirmModifier(model: model))
    }
}
