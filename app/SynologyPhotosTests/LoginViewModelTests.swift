import Testing
import Foundation
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct LoginViewModelTests {
    /// Uses a fresh `UserDefaults` suite per test so `LoginPreferencesStore`
    /// reads/writes never leak between tests or depend on ordering.
    private func freshDefaults() -> UserDefaults {
        let suite = "com.synologynativephotos.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeModel(fake: FakePhotosCore, defaults: UserDefaults? = nil) -> LoginFormModel {
        let auth = AuthStateMachine(client: fake)
        let prefs = defaults.map { LoginPreferencesStore.load(defaults: $0) } ?? .empty
        return LoginFormModel(auth: auth, client: fake, prefs: prefs)
    }

    @Test func syncShowsOtpFieldOnNeedsOtp() {
        let m = makeModel(fake: FakePhotosCore())
        m.sync(with: .needsOtp(username: "photo"))
        #expect(m.showOtp == true)
        #expect(m.errorText?.localizedCaseInsensitiveContains("code") == true)
    }

    @Test func syncShowsErrorOnInvalid() {
        let m = makeModel(fake: FakePhotosCore())
        m.sync(with: .invalid(message: "bad password"))
        #expect(m.errorText == "bad password")
        #expect(m.showOtp == false)
    }

    @Test func syncClearsErrorOnValid() {
        let m = makeModel(fake: FakePhotosCore())
        m.errorText = "stale"
        m.sync(with: .valid(Session(sid: "S", synoToken: nil, username: "photo", deviceDid: nil)))
        #expect(m.errorText == nil)
    }

    @Test func defaultsAreRememberMeOnInsecureOff() {
        let m = makeModel(fake: FakePhotosCore())
        #expect(m.rememberMe == true)
        #expect(m.allowUntrustedTls == false)
    }

    // MARK: - Cert approval (trust-on-first-use)

    /// The core scenario from the brief: fetch -> show fingerprint -> user
    /// approves -> pin stored in the Keychain -> used as the `Connection`
    /// pin for the login that follows.
    @Test func submitFetchesCertShowsFingerprintApprovePinsAndLogsIn() async throws {
        let host = "https://tofu-test.local:5001"
        defer { try? KeychainCertPin.clear(host: host) }

        let fake = FakePhotosCore()
        fake.fetchCertificateResult = .success(
            CertInfo(der: Data([1, 2, 3, 4]), sha256Hex: "AB:CD:EF", subject: "CN=tofu-test.local"))
        fake.loginResult = .success(Session(sid: "S1", synoToken: nil, username: "photo", deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = "photo"; m.password = "pw"

        // First submit: no pin stored yet, so it must stop at the
        // approval prompt without ever calling login.
        await m.submit()
        guard case .needsApproval(let info) = m.cert.phase else {
            Issue.record("expected needsApproval, got \(m.cert.phase)")
            return
        }
        #expect(info.sha256Hex == "AB:CD:EF")
        #expect(info.subject == "CN=tofu-test.local")
        #expect(fake.loginCallCount == 0)

        // Approve and retry: now the pin is stored and login proceeds
        // using it as `Connection.pinnedCertDer`.
        await m.approveCertAndRetry()

        #expect(fake.loginCallCount == 1)
        #expect(fake.lastLoginConnection?.pinnedCertDer == Data([1, 2, 3, 4]))
        #expect(try KeychainCertPin.load(host: host) == Data([1, 2, 3, 4]))
        guard case .valid(let session) = m.auth.phase else {
            Issue.record("expected valid phase after approved login")
            return
        }
        #expect(session.sid == "S1")
    }

    /// Regression test for the real-NAS bug: typing a Tailscale MagicDNS
    /// host (e.g. `fafnir.ladon-pirate.ts.net`) whose certificate's subject
    /// names a completely different, unreachable public DDNS hostname (e.g.
    /// `agnihotri.synology.me`) must never cause the app to connect to, pin,
    /// fetch a second certificate from, or log in against the SUBJECT. The
    /// subject is display-only. Every network-shaped call in this flow
    /// (`fetchCertificate`, the pin's Keychain key, and the login
    /// `Connection.host`) must carry exactly the host the user typed, from
    /// first submit through approval through the login that follows.
    @Test func loginTargetsTypedHostNeverTheCertSubject() async throws {
        let typedHost = "https://fafnir.ladon-pirate.ts.net:5001"
        let subjectHost = "CN=agnihotri.synology.me"
        defer { try? KeychainCertPin.clear(host: typedHost) }

        let fake = FakePhotosCore()
        fake.fetchCertificateResult = .success(
            CertInfo(der: Data([5, 5, 5, 5]), sha256Hex: "55:55", subject: subjectHost))
        fake.loginResult = .success(Session(sid: "TS1", synoToken: nil, username: "photo", deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = typedHost; m.username = "photo"; m.password = "pw"

        await m.submit()
        // The very first fetch must be against the typed host, never the
        // (as yet unknown, since it comes back IN the response) subject.
        #expect(fake.lastFetchCertificateHost == typedHost)
        #expect(fake.fetchCertificateCallCount == 1)

        guard case .needsApproval(let info) = m.cert.phase else {
            Issue.record("expected needsApproval, got \(m.cert.phase)")
            return
        }
        #expect(info.subject == subjectHost, "subject is shown for display only")

        await m.approveCertAndRetry()

        // No second fetch: the DER from the first fetch is reused as the pin.
        #expect(fake.fetchCertificateCallCount == 1, "approving must not trigger a second certificate fetch")
        #expect(fake.loginCallCount == 1)
        #expect(fake.lastLoginConnection?.host == typedHost, "login must target the typed host, not the cert subject")
        #expect(fake.lastLoginConnection?.host != subjectHost)
        #expect(fake.lastLoginConnection?.pinnedCertDer == Data([5, 5, 5, 5]))
        #expect(try KeychainCertPin.load(host: typedHost) == Data([5, 5, 5, 5]),
                "the pin must be stored keyed by the typed host, not the subject")
        #expect(try KeychainCertPin.load(host: subjectHost) == nil,
                "nothing should ever be pinned under the subject as a key")
        guard case .valid(let session) = m.auth.phase else {
            Issue.record("expected valid phase after approved login")
            return
        }
        #expect(session.sid == "TS1")
    }

    /// Once a host has a stored pin (from an earlier approval), a fresh
    /// `LoginFormModel`/`CertApprovalViewModel` for the same host must load
    /// it straight into `.approved` with no fetch and no approval prompt.
    @Test func submitSkipsApprovalWhenPinAlreadyStored() async throws {
        let host = "https://tofu-existing.local:5001"
        try KeychainCertPin.save(der: Data([9, 9, 9]), host: host)
        defer { try? KeychainCertPin.clear(host: host) }

        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S2", synoToken: nil, username: "photo", deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = "photo"; m.password = "pw"

        await m.submit()

        #expect(fake.fetchCertificateCallCount == 0)
        #expect(fake.loginCallCount == 1)
        #expect(fake.lastLoginConnection?.pinnedCertDer == Data([9, 9, 9]))
    }

    @Test func certFetchFailureShowsErrorWithoutAttemptingLogin() async {
        let host = "https://tofu-unreachable.local:5001"
        let fake = FakePhotosCore()
        fake.fetchCertificateResult = .failure(.Network(message: "could not connect"))

        let m = makeModel(fake: fake)
        m.host = host; m.username = "photo"; m.password = "pw"

        await m.submit()

        #expect(fake.loginCallCount == 0)
        #expect(m.errorText != nil)
    }

    // MARK: - Insecure toggle

    @Test func insecureToggleSetsAllowUntrustedTlsOnConnection() async throws {
        let host = "https://insecure-test.local:5001"
        try KeychainCertPin.save(der: Data([1]), host: host) // skip the approval prompt for this test
        defer { try? KeychainCertPin.clear(host: host) }

        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S3", synoToken: nil, username: "photo", deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = "photo"; m.password = "pw"
        m.allowUntrustedTls = true

        await m.submit()

        #expect(fake.lastLoginConnection?.allowUntrustedTls == true)
    }

    @Test func insecureToggleDefaultsOffOnConnection() async throws {
        let host = "https://secure-test.local:5001"
        try KeychainCertPin.save(der: Data([1]), host: host)
        defer { try? KeychainCertPin.clear(host: host) }

        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S4", synoToken: nil, username: "photo", deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = "photo"; m.password = "pw"

        await m.submit()

        #expect(fake.lastLoginConnection?.allowUntrustedTls == false)
    }

    // MARK: - Remember me

    @Test func rememberMeOnPersistsSessionForRestore() async throws {
        let host = "https://remember-on.local:5001"
        let username = "rememberonuser"
        try KeychainCertPin.save(der: Data([1]), host: host)
        defer {
            try? KeychainCertPin.clear(host: host)
            try? KeychainSID.clear(host: host, username: username)
        }

        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S5", synoToken: "TOK5", username: username, deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = username; m.password = "pw"
        m.rememberMe = true

        await m.submit()

        let stored = try KeychainSID.load(host: host, username: username)
        #expect(stored?.sid == "S5")

        // A later restore against the same (host, username) must land
        // back on `.valid` using exactly what was persisted.
        let restoreAuth = AuthStateMachine(client: fake)
        await restoreAuth.restore(host: host, username: username)
        guard case .valid(let restored) = restoreAuth.phase else {
            Issue.record("expected valid after restore, got \(restoreAuth.phase)")
            return
        }
        #expect(restored.sid == "S5")
    }

    @Test func rememberMeOffDoesNotPersistSession() async throws {
        let host = "https://remember-off.local:5001"
        let username = "rememberoffuser"
        try KeychainCertPin.save(der: Data([1]), host: host)
        defer {
            try? KeychainCertPin.clear(host: host)
            try? KeychainSID.clear(host: host, username: username)
        }

        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S6", synoToken: nil, username: username, deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = username; m.password = "pw"
        m.rememberMe = false

        await m.submit()

        // The phase itself is still valid for this run (remember-me only
        // controls whether a *future launch* can restore it).
        guard case .valid = m.auth.phase else {
            Issue.record("expected valid phase for the current run regardless of remember-me")
            return
        }
        #expect(try KeychainSID.load(host: host, username: username) == nil)
    }

    @Test func rememberMeOffClearsAnyPriorStoredSessionForSameAccount() async throws {
        let host = "https://remember-off-clears.local:5001"
        let username = "clearprioruser"
        try KeychainSID.save(Session(sid: "OLD", synoToken: nil, username: username, deviceDid: nil), host: host)
        try KeychainCertPin.save(der: Data([1]), host: host)
        defer {
            try? KeychainCertPin.clear(host: host)
            try? KeychainSID.clear(host: host, username: username)
        }

        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "NEW", synoToken: nil, username: username, deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = username; m.password = "pw"
        m.rememberMe = false

        await m.submit()

        #expect(try KeychainSID.load(host: host, username: username) == nil)
    }

    /// Pinning is server-identity material, not session material: turning
    /// remember-me off must not remove the pin that was just approved.
    @Test func rememberMeOffKeepsCertPin() async throws {
        let host = "https://remember-off-keeps-pin.local:5001"
        let username = "keeppinuser"
        defer {
            try? KeychainCertPin.clear(host: host)
            try? KeychainSID.clear(host: host, username: username)
        }

        let fake = FakePhotosCore()
        fake.fetchCertificateResult = .success(
            CertInfo(der: Data([7, 7, 7]), sha256Hex: "77:77", subject: "CN=remember-off-keeps-pin.local"))
        fake.loginResult = .success(Session(sid: "S7", synoToken: nil, username: username, deviceDid: nil))

        let m = makeModel(fake: fake)
        m.host = host; m.username = username; m.password = "pw"
        m.rememberMe = false

        await m.submit() // stops at approval
        await m.approveCertAndRetry()

        #expect(try KeychainCertPin.load(host: host) == Data([7, 7, 7]))
        #expect(try KeychainSID.load(host: host, username: username) == nil)
    }

    // MARK: - Device token 2FA

    /// A login that requires OTP and succeeds with `enable_device_token`
    /// must persist the token the core returned on `Session.deviceDid`.
    @Test func otpLoginStoresReturnedDeviceToken() async throws {
        let host = "https://devicetoken-store.local:5001"
        let username = "devicetokenuser"
        try KeychainCertPin.save(der: Data([1]), host: host)
        defer {
            try? KeychainCertPin.clear(host: host)
            try? KeychainSID.clear(host: host, username: username)
            try? KeychainDeviceToken.clear(host: host, username: username)
        }

        let fake = FakePhotosCore()
        fake.loginResult = .success(
            Session(sid: "S8", synoToken: nil, username: username, deviceDid: "DEVICE-TOKEN-XYZ"))

        let m = makeModel(fake: fake)
        m.host = host; m.username = username; m.password = "pw"
        m.showOtp = true; m.otpCode = "123456"

        await m.submit()

        #expect(try KeychainDeviceToken.load(host: host, username: username) == "DEVICE-TOKEN-XYZ")
    }

    /// On a later login attempt for the same (host, username), the stored
    /// device token must be loaded and sent, and DSM (the fake, standing
    /// in for it) must accept it without requiring an OTP code at all.
    @Test func reLoginSendsStoredDeviceTokenAndSkipsOtp() async throws {
        let host = "https://devicetoken-send.local:5001"
        let username = "devicetokenresend"
        try KeychainCertPin.save(der: Data([1]), host: host)
        try KeychainDeviceToken.save("STORED-TOKEN-1", host: host, username: username)
        defer {
            try? KeychainCertPin.clear(host: host)
            try? KeychainSID.clear(host: host, username: username)
            try? KeychainDeviceToken.clear(host: host, username: username)
        }

        let fake = FakePhotosCore()
        // Without the right device token, login would need an OTP; the
        // fake models this exactly like the real DSM contract (see
        // `synology_api::auth::login`'s doc comment): a login attempted
        // with no accepted token, and no OTP either, fails closed.
        fake.loginResult = .failure(.OtpRequired)
        fake.acceptedDeviceToken = "STORED-TOKEN-1"
        fake.deviceTokenLoginResult = .success(
            Session(sid: "S9", synoToken: nil, username: username, deviceDid: "STORED-TOKEN-1"))

        let m = makeModel(fake: fake)
        m.host = host; m.username = username; m.password = "pw"
        // Deliberately no OTP typed in and `showOtp` left false: the
        // stored device token alone must be enough.

        await m.submit()

        #expect(fake.lastDeviceToken == .some(.some("STORED-TOKEN-1")))
        #expect(fake.lastOtpCode == .some(.none))
        guard case .valid(let session) = m.auth.phase else {
            Issue.record("expected valid phase, stored device token should have skipped OTP, got \(m.auth.phase)")
            return
        }
        #expect(session.sid == "S9")
    }
}
