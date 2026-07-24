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
    private static let service = "com.synologynativephotos.session"

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
}
