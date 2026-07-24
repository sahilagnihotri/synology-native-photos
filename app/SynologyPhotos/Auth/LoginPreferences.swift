import Foundation

/// Non-secret login form prefill, persisted in `UserDefaults`.
///
/// Nothing stored here is sensitive: host, username, and the two trust
/// toggles are all things the user typed or chose in plain sight, none of
/// them a credential. The password never goes anywhere near this type, on
/// purpose, per the brief's "pre-fill host + username + trust settings,
/// NEVER the password" rule; `UserDefaults` is deliberately the wrong place
/// to ever put a password, which is precisely why it is fine for this.
///
/// `rememberMe` itself is persisted here too (as the toggle's own last
/// setting), separate from what it gates: whether a *session* got saved to
/// `KeychainSID`. That gate is enforced by `AuthStateMachine.attemptLogin`,
/// not by this type.
struct LoginPreferences: Equatable {
    var host: String
    var username: String
    var rememberMe: Bool
    var allowUntrustedTls: Bool

    static let empty = LoginPreferences(host: "", username: "", rememberMe: true, allowUntrustedTls: false)
}

enum LoginPreferencesStore {
    private static let hostKey = "com.synologynativephotos.login.host"
    private static let usernameKey = "com.synologynativephotos.login.username"
    private static let rememberMeKey = "com.synologynativephotos.login.rememberMe"
    private static let allowUntrustedTlsKey = "com.synologynativephotos.login.allowUntrustedTls"

    /// Loads the last saved prefill, or `.empty` (remember-me defaulting to
    /// on, the insecure toggle defaulting to off) on a fresh install where
    /// nothing has been saved yet.
    static func load(defaults: UserDefaults = .standard) -> LoginPreferences {
        guard defaults.object(forKey: hostKey) != nil else {
            return .empty
        }
        return LoginPreferences(
            host: defaults.string(forKey: hostKey) ?? "",
            username: defaults.string(forKey: usernameKey) ?? "",
            rememberMe: defaults.bool(forKey: rememberMeKey),
            allowUntrustedTls: defaults.bool(forKey: allowUntrustedTlsKey)
        )
    }

    /// Saves `prefs` for the next launch's prefill.
    static func save(_ prefs: LoginPreferences, defaults: UserDefaults = .standard) {
        defaults.set(prefs.host, forKey: hostKey)
        defaults.set(prefs.username, forKey: usernameKey)
        defaults.set(prefs.rememberMe, forKey: rememberMeKey)
        defaults.set(prefs.allowUntrustedTls, forKey: allowUntrustedTlsKey)
    }

    /// Clears every saved prefill value. Used when the user explicitly
    /// wants a clean slate (not currently wired to any UI action, kept for
    /// symmetry with the other stores' `clear`).
    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: hostKey)
        defaults.removeObject(forKey: usernameKey)
        defaults.removeObject(forKey: rememberMeKey)
        defaults.removeObject(forKey: allowUntrustedTlsKey)
    }
}
