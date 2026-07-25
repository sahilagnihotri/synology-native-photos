import Testing
import Foundation
@testable import SynologyPhotos

struct CacheSettingsStoreTests {
    /// A throwaway `UserDefaults` suite so a test never touches (or is
    /// polluted by) the shared standard domain.
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "cache-settings-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, name)
    }

    @Test func unsetKeysReadBackGenerousDefaults() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CacheSettingsStore(defaults: defaults)
        #expect(store.ramLimitBytes == CacheSizeDefaults.ramDefaultBytes)
        #expect(store.diskLimitBytes == CacheSizeDefaults.diskDefaultBytes)
    }

    @Test func writesArePersistedAndReadBack() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var store = CacheSettingsStore(defaults: defaults)
        store.ramLimitBytes = 2 * CacheSizeDefaults.bytesPerGB
        store.diskLimitBytes = 16 * CacheSizeDefaults.bytesPerGB

        // A brand-new store over the same defaults sees the persisted values,
        // proving they survive a relaunch.
        let reopened = CacheSettingsStore(defaults: defaults)
        #expect(reopened.ramLimitBytes == 2 * CacheSizeDefaults.bytesPerGB)
        #expect(reopened.diskLimitBytes == 16 * CacheSizeDefaults.bytesPerGB)
    }

    @Test func writesBelowMinimumAreClampedUp() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var store = CacheSettingsStore(defaults: defaults)
        store.ramLimitBytes = 1
        store.diskLimitBytes = 1
        #expect(store.ramLimitBytes == CacheSizeDefaults.ramMinBytes)
        #expect(store.diskLimitBytes == CacheSizeDefaults.diskMinBytes)
    }

    @Test func writesAboveMaximumAreClampedDown() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        var store = CacheSettingsStore(defaults: defaults)
        store.ramLimitBytes = 999 * CacheSizeDefaults.bytesPerGB
        store.diskLimitBytes = 999 * CacheSizeDefaults.bytesPerGB
        #expect(store.ramLimitBytes == CacheSizeDefaults.ramMaxBytes)
        #expect(store.diskLimitBytes == CacheSizeDefaults.diskMaxBytes)
    }

    @Test func anOutOfRangeStoredValueIsClampedOnRead() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        // Simulate a hand-edited / corrupt defaults entry written straight to
        // the key, bypassing the clamping setter.
        defaults.set(0, forKey: CacheSizeDefaults.ramKey)
        defaults.set(500 * CacheSizeDefaults.bytesPerGB, forKey: CacheSizeDefaults.diskKey)
        let store = CacheSettingsStore(defaults: defaults)
        #expect(store.ramLimitBytes == CacheSizeDefaults.ramMinBytes)
        #expect(store.diskLimitBytes == CacheSizeDefaults.diskMaxBytes)
    }
}

@MainActor
struct CacheSettingsModelTests {
    private func freshStore() -> (CacheSettingsStore, UserDefaults, String) {
        let name = "cache-model-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (CacheSettingsStore(defaults: defaults), defaults, name)
    }

    @Test func modelLoadsInitialValuesFromTheStore() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CacheSettingsModel(store: store, cache: nil)
        #expect(model.ramLimitBytes == CacheSizeDefaults.ramDefaultBytes)
        #expect(model.diskLimitBytes == CacheSizeDefaults.diskDefaultBytes)
    }

    @Test func changingAModelValuePersistsThroughTheStore() {
        let (store, defaults, name) = freshStore()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = CacheSettingsModel(store: store, cache: nil)

        model.ramLimitBytes = 3 * CacheSizeDefaults.bytesPerGB
        model.diskLimitBytes = 20 * CacheSizeDefaults.bytesPerGB

        // A fresh store over the same defaults sees the values the model wrote,
        // proving the model persists (and that its live-apply path is safe with
        // no attached cache).
        let reopened = CacheSettingsStore(defaults: defaults)
        #expect(reopened.ramLimitBytes == 3 * CacheSizeDefaults.bytesPerGB)
        #expect(reopened.diskLimitBytes == 20 * CacheSizeDefaults.bytesPerGB)
    }
}
