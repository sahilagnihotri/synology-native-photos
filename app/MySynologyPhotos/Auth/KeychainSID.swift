import Foundation
import Security
import PhotosCore

/// A DSM session persisted to disk. Mirrors the fields of the Rust core's
/// `Session` plus the host it was issued by, so a stored session can be
/// looked up and restored without needing a live network round trip first.
struct StoredSession: Codable, Equatable {
    let sid: String
    let synoToken: String?
    let username: String
    let deviceDid: String?
    let host: String
}

enum KeychainError: Error {
    case unexpectedStatus(OSStatus)
    case encodeFailed
    case decodeFailed
}

/// Session persistence in the macOS Keychain, keyed per (host, username).
///
/// Stored as a generic-password item. The item is scoped to this device only
/// and requires the device to have been unlocked at least once since boot;
/// it is never made available to iCloud Keychain sync, since this app only
/// ever talks to the user's own NAS and must not leak session material off
/// the device.
enum KeychainSID {
    private static let service = "se.agnihotri.mysynologyphotos.session"

    private static func account(host: String, username: String) -> String {
        "\(host)|\(username)"
    }

    /// Attributes shared by every query against this app's keychain items.
    private static func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// Saves `session` for `host`, replacing any existing entry for the same
    /// (host, username) pair. Update-or-insert: an existing item is deleted
    /// first so a stale value can never linger alongside a new one.
    static func save(_ session: Session, host: String) throws {
        let stored = StoredSession(
            sid: session.sid,
            synoToken: session.synoToken,
            username: session.username,
            deviceDid: session.deviceDid,
            host: host
        )
        guard let data = try? JSONEncoder().encode(stored) else {
            throw KeychainError.encodeFailed
        }

        let acct = account(host: host, username: session.username)
        let query = baseQuery(account: acct)

        // Remove any prior entry so this is always a clean update-or-insert.
        SecItemDelete(query as CFDictionary)

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // Never sync this item to iCloud Keychain. The app is Synology-only
        // and session material must stay on this Mac.
        add[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads the stored session for (host, username), or `nil` if none exists.
    static func load(host: String, username: String) throws -> StoredSession? {
        var query = baseQuery(account: account(host: host, username: username))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            throw KeychainError.decodeFailed
        }
        return stored
    }

    /// Removes the stored session for (host, username), if any. Absence is
    /// not an error, so callers can clear unconditionally on sign-out.
    static func clear(host: String, username: String) throws {
        let query = baseQuery(account: account(host: host, username: username))
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every session this app has stored, across all hosts and
    /// accounts. Intended for a full sign-out / reset.
    static func clearAll() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns the single stored session, if any, without the caller
    /// needing to already know its (host, username).
    ///
    /// This app supports exactly one signed-in account at a time
    /// (`SignOutController`'s contract), so at most one item should ever
    /// exist under this service; launch-time restore uses this to recover
    /// which account to attempt `AuthStateMachine.restore(host:username:)`
    /// against without persisting the username anywhere outside the
    /// Keychain itself. If more than one item is somehow present (e.g.
    /// leftover state from a build predating the single-account
    /// invariant), the query's own ordering picks one and the rest are
    /// simply not returned; it does not attempt to merge or choose among
    /// them.
    static func loadMostRecentAccount() throws -> StoredSession? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: data) else {
            throw KeychainError.decodeFailed
        }
        return stored
    }
}

/// Legacy Keychain-backed pin storage, kept only as a one-time migration
/// source for `KeychainCertPin`. Do not add new callers: this is the store
/// that caused the repeated "wants to use your confidential information"
/// prompt, because a pinned certificate is public server-identity data, not
/// a secret, and never belonged in the Keychain in the first place.
private enum LegacyKeychainCertPin {
    static let service = "se.agnihotri.mysynologyphotos.certpin"

    static func baseQuery(host: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let host {
            query[kSecAttrAccount as String] = host
        }
        return query
    }

    static func load(host: String) throws -> Data? {
        var query = baseQuery(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = out as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }
        return data
    }

    static func clear(host: String) throws {
        let status = SecItemDelete(baseQuery(host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Every host this legacy store still has an item for. Used once at
    /// startup to migrate every pin, not just the currently-active host,
    /// since a prior launch may have approved more than one host.
    static func allHosts() throws -> [String] {
        var query = baseQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            throw KeychainError.unexpectedStatus(status)
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}

/// Trust-on-first-use certificate pin storage, keyed per host.
///
/// A pin is server-identity material, not a secret: it says "this is the
/// certificate this host presented and the user approved", independent of
/// which account is signed in or whether "remember me" is on. Unlike
/// `KeychainSID`/`KeychainDeviceToken`, it is stored as a plain file under
/// Application Support rather than in the Keychain, because reading a
/// Keychain item triggers a system access prompt and there is nothing
/// confidential here for that prompt to protect; storing it in the
/// Keychain was the cause of the repeated launch-time prompt this type
/// replaces. Kept independent of `StoredSession` for the same reason as
/// before: `LoginFormModel`'s remember-me toggle never clears it (see the
/// brief's explicit call-out that pinning survives a remember-me-off
/// sign-out).
enum KeychainCertPin {
    /// `~/Library/Application Support/SynologyNativePhotos/pins`. Each pin
    /// is one `<sanitized-host>.der` file holding the raw certificate DER,
    /// nothing else, so the file itself is exactly the pinned bytes.
    private static func pinsDir() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SynologyNativePhotos", isDirectory: true)
            .appendingPathComponent("pins", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }

    /// Host strings (e.g. `https://fafnir.ladon-pirate.ts.net:5001`) contain
    /// characters that are awkward or unsafe as a bare filename (`:`, `/`).
    /// Percent-encoding keeps the mapping one-to-one and reversible-in-spirit
    /// without needing a real path-component allowlist.
    private static func fileName(for host: String) -> String {
        let encoded = host.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? host
        return "\(encoded).der"
    }

    private static func fileURL(for host: String) throws -> URL {
        try pinsDir().appendingPathComponent(fileName(for: host))
    }

    /// Saves the approved certificate DER for `host`, replacing any prior
    /// pin for the same host. A later mismatched cert from the same host
    /// is the core's problem to reject (see `synology_api::build_client`);
    /// this store only ever holds the single most recently approved DER.
    static func save(der: Data, host: String) throws {
        let url = try fileURL(for: host)
        try der.write(to: url, options: .atomic)
    }

    /// Loads the pinned certificate DER for `host`, or `nil` if this host
    /// has never had a cert approved (i.e. still needs the TOFU prompt).
    ///
    /// Also runs the one-time Keychain migration for `host`: if a pin from
    /// the legacy Keychain store exists and no file has been written yet,
    /// it is copied to the file store and deleted from the Keychain so the
    /// old item (and the prompt it caused) does not linger.
    static func load(host: String) throws -> Data? {
        let url = try fileURL(for: host)
        if let data = try? Data(contentsOf: url) {
            return data
        }
        if let legacy = try LegacyKeychainCertPin.load(host: host) {
            try save(der: legacy, host: host)
            try? LegacyKeychainCertPin.clear(host: host)
            return legacy
        }
        return nil
    }

    /// Removes the pin for `host`, if any (file store and, in case a
    /// migration has not run yet, the legacy Keychain store too). Forces
    /// the next connect to that host back through the TOFU approval prompt
    /// (e.g. after a deliberate "forget this server" action, or if the
    /// user suspects the pin was approved against the wrong certificate).
    static func clear(host: String) throws {
        let url = try fileURL(for: host)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try? LegacyKeychainCertPin.clear(host: host)
    }

    /// Migrates every pin still sitting in the legacy Keychain store to the
    /// file store, deleting each Keychain item as it goes. Meant to be
    /// called once at launch (before any per-host `load`) so hosts that are
    /// not the one currently being connected to (e.g. a previously-approved
    /// host from an earlier session) are not left behind indefinitely,
    /// silently re-prompting only when eventually looked up.
    static func migrateAllFromLegacyKeychain() {
        guard let hosts = try? LegacyKeychainCertPin.allHosts() else { return }
        for host in hosts {
            guard let der = (try? LegacyKeychainCertPin.load(host: host)) ?? nil else { continue }
            if (try? save(der: der, host: host)) != nil {
                try? LegacyKeychainCertPin.clear(host: host)
            }
        }
    }
}

/// DSM device-trust token storage, keyed per (host, username), matching
/// `KeychainSID`'s account-scoping.
///
/// Kept separate from `StoredSession` (rather than folding into it) because
/// its lifetime is different: `StoredSession` is cleared whenever
/// remember-me is off, but a device token stays useful (and, per the brief,
/// is kept) across a plain sign-out. Only an explicit "forget this device"
/// action clears it.
enum KeychainDeviceToken {
    private static let service = "se.agnihotri.mysynologyphotos.devicetoken"

    private static func account(host: String, username: String) -> String {
        "\(host)|\(username)"
    }

    private static func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }

    /// Saves `token` for (host, username), replacing any existing entry.
    static func save(_ token: String, host: String, username: String) throws {
        let acct = account(host: host, username: username)
        let query = baseQuery(account: acct)
        SecItemDelete(query as CFDictionary)

        guard let data = token.data(using: .utf8) else {
            throw KeychainError.encodeFailed
        }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads the stored device token for (host, username), or `nil` if
    /// this device has never been trusted for this account (or the token
    /// was explicitly forgotten).
    static func load(host: String, username: String) throws -> String? {
        var query = baseQuery(account: account(host: host, username: username))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = out as? Data, let token = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedStatus(status)
        }
        return token
    }

    /// Removes the stored device token for (host, username). This is the
    /// "forget this device" action: DSM will require a fresh OTP on the
    /// next login from this Mac for this account. Absence is not an error.
    static func clear(host: String, username: String) throws {
        let status = SecItemDelete(baseQuery(account: account(host: host, username: username)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
