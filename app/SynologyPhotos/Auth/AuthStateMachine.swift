import Foundation
import PhotosCore

/// Every state the login UI can be in, driven entirely by `AuthStateMachine`.
///
/// `needsOtp` carries the username so the OTP screen can re-show it without
/// the caller having to thread it through separately, and `valid` carries the
/// live `Session` the rest of the app needs to make authenticated calls.
enum AuthPhase: Equatable {
    case loggedOut
    case authenticating
    case needsOtp(username: String)
    case restoring
    case valid(Session)
    case expired
    case invalid(message: String)

    static func == (l: AuthPhase, r: AuthPhase) -> Bool {
        switch (l, r) {
        case (.loggedOut, .loggedOut), (.authenticating, .authenticating),
             (.restoring, .restoring), (.expired, .expired): return true
        case let (.needsOtp(a), .needsOtp(b)): return a == b
        case let (.valid(a), .valid(b)): return a == b
        case let (.invalid(a), .invalid(b)): return a == b
        default: return false
        }
    }
}

/// Drives the login UI end to end: idle, authenticating, needing a 2FA code,
/// restoring a stored session, or landed on valid/expired/invalid.
///
/// Depends on `PhotosCoreProtocol` directly rather than a concrete client so
/// tests can inject `FakePhotosCore` and drive every transition without a
/// live NAS. `phase` is the single source of truth the login view observes;
/// every method here only ever moves `phase` forward along a transition the
/// brief defines, never leaves it in a half-updated state.
@MainActor
@Observable
final class AuthStateMachine {
    private let client: PhotosCoreProtocol
    var phase: AuthPhase = .loggedOut

    init(client: PhotosCoreProtocol) {
        self.client = client
    }

    /// Attempts a login (or an OTP-code retry of one). On success the phase
    /// becomes `.valid` and the session is persisted to the Keychain so a
    /// later launch can `restore` it. On `CoreError.OtpRequired` the phase
    /// becomes `.needsOtp(username:)` so the view can re-prompt for a code
    /// and call this again with `otpCode` set. Any other failure becomes
    /// `.invalid(message:)` with a message suitable for display.
    func attemptLogin(
        host: String,
        username: String,
        password: String,
        otpCode: String?,
        pinnedCertDer: Data?
    ) async {
        phase = .authenticating
        let connection = Connection(host: host, verifyTls: true, pinnedCertDer: pinnedCertDer)
        do {
            let session = try await client.login(
                connection: connection,
                username: username,
                password: password,
                otpCode: otpCode
            )
            try? KeychainSID.save(session, host: host)
            phase = .valid(session)
        } catch let error as CoreError {
            switch error {
            case .OtpRequired:
                phase = .needsOtp(username: username)
            default:
                phase = .invalid(message: error.userMessage)
            }
        } catch {
            phase = .invalid(message: error.localizedDescription)
        }
    }

    /// Restores a previously saved session for (host, username) without
    /// re-prompting for credentials, e.g. on app launch. Absence of a stored
    /// session or a decode failure is treated as a plain sign-out (back to
    /// `.loggedOut`) rather than an error, since there is nothing to recover.
    func restore(host: String, username: String) async {
        guard let stored = (try? KeychainSID.load(host: host, username: username)) ?? nil else {
            phase = .loggedOut
            return
        }
        phase = .restoring
        let session = Session(
            sid: stored.sid,
            synoToken: stored.synoToken,
            username: stored.username,
            deviceDid: stored.deviceDid
        )
        let connection = Connection(host: host, verifyTls: true, pinnedCertDer: nil)
        do {
            let state = try await client.restoreSession(connection: connection, session: session)
            switch state {
            case .valid:
                phase = .valid(session)
            case .expired:
                phase = .expired
            case .invalid:
                phase = .invalid(message: "Stored session is no longer valid.")
            }
        } catch let error as CoreError {
            if error.isRetryable {
                // Transient/server trouble: don't discard the stored session
                // outright, let the user retry rather than forcing a full
                // re-login for what may just be a dropped connection.
                phase = .expired
            } else {
                phase = .invalid(message: error.userMessage)
            }
        } catch {
            phase = .expired
        }
    }

    /// Forces the phase to `.expired`, e.g. when a later authenticated call
    /// comes back with a session-expired signal outside of `restore`.
    func markExpired() {
        phase = .expired
    }

    /// Returns to `.loggedOut`, the state a signed-out or freshly launched
    /// app should present. Does not touch the Keychain; callers that mean
    /// "sign out" should clear the stored session themselves first.
    func reset() {
        phase = .loggedOut
    }
}
