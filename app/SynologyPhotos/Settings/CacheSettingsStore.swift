import Foundation

/// Byte-size policy for the original-image caches: the generous defaults and
/// the hard bounds a persisted value is clamped into. Kept as pure constants
/// (no `UserDefaults`) so the clamping is unit-testable in isolation.
///
/// Defaults are deliberately generous: the target machine has 64-128 GB of RAM
/// and NVMe storage, so a 1 GB decoded-image budget and a 4 GB on-disk
/// original budget cost little and keep re-opens instant.
enum CacheSizeDefaults {
    static let bytesPerMB = 1024 * 1024
    static let bytesPerGB = 1024 * 1024 * 1024

    static let ramDefaultBytes = 1 * bytesPerGB
    static let ramMinBytes = 64 * bytesPerMB
    static let ramMaxBytes = 8 * bytesPerGB

    static let diskDefaultBytes = 4 * bytesPerGB
    static let diskMinBytes = 256 * bytesPerMB
    static let diskMaxBytes = 64 * bytesPerGB

    static let ramKey = "cache.original.ramLimitBytes"
    static let diskKey = "cache.original.diskLimitBytes"

    static func clampRam(_ bytes: Int) -> Int { min(max(bytes, ramMinBytes), ramMaxBytes) }
    static func clampDisk(_ bytes: Int) -> Int { min(max(bytes, diskMinBytes), diskMaxBytes) }
}

/// Reads and writes the cache byte budgets in `UserDefaults`, so a size the
/// user picks survives relaunch. Backed by an injectable `UserDefaults` so
/// tests can run against a throwaway suite rather than the shared domain.
///
/// An unset key reads back the generous default; a stored value is clamped
/// into the allowed bounds on both read and write, so a hand-edited or
/// out-of-range defaults entry can never push the caches to an absurd size.
struct CacheSettingsStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var ramLimitBytes: Int {
        get {
            guard defaults.object(forKey: CacheSizeDefaults.ramKey) != nil else {
                return CacheSizeDefaults.ramDefaultBytes
            }
            return CacheSizeDefaults.clampRam(defaults.integer(forKey: CacheSizeDefaults.ramKey))
        }
        nonmutating set {
            defaults.set(CacheSizeDefaults.clampRam(newValue), forKey: CacheSizeDefaults.ramKey)
        }
    }

    var diskLimitBytes: Int {
        get {
            guard defaults.object(forKey: CacheSizeDefaults.diskKey) != nil else {
                return CacheSizeDefaults.diskDefaultBytes
            }
            return CacheSizeDefaults.clampDisk(defaults.integer(forKey: CacheSizeDefaults.diskKey))
        }
        nonmutating set {
            defaults.set(CacheSizeDefaults.clampDisk(newValue), forKey: CacheSizeDefaults.diskKey)
        }
    }
}
