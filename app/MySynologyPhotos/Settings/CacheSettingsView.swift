import SwiftUI

/// Backs the cache Settings panel: holds the current RAM/disk byte budgets as
/// observable values the sliders bind to, persists any change through
/// `CacheSettingsStore`, and live-applies it to the running
/// `OriginalImageCache` so a resize takes effect without a relaunch. Also
/// surfaces current disk usage and the "Clear cache" action.
///
/// The `cache` is optional so the panel still renders (persistence only) on the
/// rare launch where the local store failed to open and there is no live cache
/// to apply changes to.
@MainActor
@Observable
final class CacheSettingsModel {
    var ramLimitBytes: Int {
        didSet { store.ramLimitBytes = ramLimitBytes; applyRam() }
    }
    var diskLimitBytes: Int {
        didSet { store.diskLimitBytes = diskLimitBytes; applyDisk() }
    }

    /// Bytes currently resident in the disk tier, refreshed from the live
    /// cache; 0 when there is no cache to read.
    private(set) var diskUsageBytes = 0
    private(set) var diskFileCount = 0

    private var store: CacheSettingsStore
    private let cache: OriginalImageCache?

    init(store: CacheSettingsStore = CacheSettingsStore(), cache: OriginalImageCache?) {
        self.store = store
        self.cache = cache
        self.ramLimitBytes = store.ramLimitBytes
        self.diskLimitBytes = store.diskLimitBytes
    }

    private func applyRam() {
        guard let cache else { return }
        let bytes = ramLimitBytes
        Task { await cache.setRamLimit(bytes) }
    }

    private func applyDisk() {
        guard let cache else { return }
        let bytes = diskLimitBytes
        Task {
            await cache.setDiskLimit(bytes)
            await refreshUsage()
        }
    }

    func refreshUsage() async {
        guard let cache else { return }
        diskUsageBytes = await cache.currentDiskUsage()
        diskFileCount = await cache.diskFileCount()
    }

    func clearCache() async {
        guard let cache else { return }
        await cache.clear()
        await refreshUsage()
    }
}

/// The cache Settings panel (Preferences window). Two sliders, RAM in MB and
/// disk in GB, a live usage readout, and a Clear Cache button. Changes persist
/// immediately (see `CacheSettingsModel`), so there is no explicit Save.
struct CacheSettingsView: View {
    @State var model: CacheSettingsModel
    @State private var isClearing = false

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    var body: some View {
        Form {
            Section("Memory Cache") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Decoded images in memory")
                        Spacer()
                        Text(Self.byteFormatter.string(fromByteCount: Int64(model.ramLimitBytes)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("settings.cache.ram.value")
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.ramLimitBytes) },
                            set: { model.ramLimitBytes = Int($0) }),
                        in: Double(CacheSizeDefaults.ramMinBytes)...Double(CacheSizeDefaults.ramMaxBytes),
                        step: Double(64 * CacheSizeDefaults.bytesPerMB))
                        .accessibilityIdentifier("settings.cache.ram.slider")
                }
            }

            Section("Disk Cache") {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Downloaded originals on disk")
                        Spacer()
                        Text(Self.byteFormatter.string(fromByteCount: Int64(model.diskLimitBytes)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .accessibilityIdentifier("settings.cache.disk.value")
                    }
                    Slider(
                        value: Binding(
                            get: { Double(model.diskLimitBytes) },
                            set: { model.diskLimitBytes = Int($0) }),
                        in: Double(CacheSizeDefaults.diskMinBytes)...Double(CacheSizeDefaults.diskMaxBytes),
                        step: Double(CacheSizeDefaults.bytesPerGB / 4))
                        .accessibilityIdentifier("settings.cache.disk.slider")
                }
                HStack {
                    Text("Currently using")
                    Spacer()
                    Text("\(Self.byteFormatter.string(fromByteCount: Int64(model.diskUsageBytes))) in \(model.diskFileCount) files")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.cache.disk.usage")
                }
                Button(role: .destructive) {
                    isClearing = true
                    Task {
                        await model.clearCache()
                        isClearing = false
                    }
                } label: {
                    if isClearing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Clear Cache")
                    }
                }
                .disabled(isClearing)
                .accessibilityIdentifier("settings.cache.clear")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 340)
        .task { await model.refreshUsage() }
    }
}
