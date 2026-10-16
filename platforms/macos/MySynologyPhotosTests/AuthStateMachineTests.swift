import Testing
import PhotosCore
@testable import MySynologyPhotos

@MainActor
struct AuthStateMachineTests {
    @Test func successfulLoginBecomesValid() async {
        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S1", synoToken: nil, username: "photo", deviceDid: nil))
        let sm = AuthStateMachine(client: fake)
        await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: nil, pinnedCertDer: nil)
        guard case .valid(let s) = sm.phase else {
            Issue.record("expected valid, got \(sm.phase)")
            return
        }
        #expect(s.sid == "S1")
    }

    @Test func otpRequiredMovesToNeedsOtp() async {
        let fake = FakePhotosCore()
        fake.loginResult = .failure(.OtpRequired)
        let sm = AuthStateMachine(client: fake)
        await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: nil, pinnedCertDer: nil)
        #expect(sm.phase == .needsOtp(username: "photo"))
    }

    @Test func badCredentialsBecomesInvalid() async {
        let fake = FakePhotosCore()
        fake.loginResult = .failure(.Auth(message: "no such account"))
        let sm = AuthStateMachine(client: fake)
        await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "bad", otpCode: nil, pinnedCertDer: nil)
        guard case .invalid(let message) = sm.phase else {
            Issue.record("expected invalid, got \(sm.phase)")
            return
        }
        #expect(message == "Sign in failed. no such account")
    }

    @Test func otpRetryWithCodeSucceeds() async {
        let fake = FakePhotosCore()
        fake.loginResult = .failure(.OtpRequired)
        let sm = AuthStateMachine(client: fake)
        await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: nil, pinnedCertDer: nil)
        #expect(sm.phase == .needsOtp(username: "photo"))

        fake.loginResult = .success(Session(sid: "S2", synoToken: nil, username: "photo", deviceDid: "DID"))
        await sm.attemptLogin(host: "https://h:5001", username: "photo", password: "pw", otpCode: "654321", pinnedCertDer: nil)
        guard case .valid(let s) = sm.phase else {
            Issue.record("expected valid, got \(sm.phase)")
            return
        }
        #expect(s.sid == "S2")
        #expect(fake.lastOtpCode == .some("654321"))
    }

    @Test func restoreExpiredMarksExpired() async {
        let fake = FakePhotosCore()
        fake.restoreResult = .success(.expired)
        let sm = AuthStateMachine(client: fake)
        let host = "https://h:5001"
        try? KeychainSID.save(Session(sid: "OLD", synoToken: nil, username: "restuser", deviceDid: nil), host: host)
        defer { try? KeychainSID.clear(host: host, username: "restuser") }

        await sm.restore(host: host, username: "restuser")
        #expect(sm.phase == .expired)
    }

    @Test func restoreValidBecomesValid() async {
        let fake = FakePhotosCore()
        fake.restoreResult = .success(.valid)
        let sm = AuthStateMachine(client: fake)
        let host = "https://h:5001"
        try? KeychainSID.save(Session(sid: "RESTORED", synoToken: "TOK", username: "restuser2", deviceDid: nil), host: host)
        defer { try? KeychainSID.clear(host: host, username: "restuser2") }

        await sm.restore(host: host, username: "restuser2")
        guard case .valid(let s) = sm.phase else {
            Issue.record("expected valid, got \(sm.phase)")
            return
        }
        #expect(s.sid == "RESTORED")
    }

    @Test func restoreWithNoStoredSessionStaysLoggedOut() async {
        let fake = FakePhotosCore()
        let sm = AuthStateMachine(client: fake)
        await sm.restore(host: "https://h:5001", username: "nobody-ever-saved")
        #expect(sm.phase == .loggedOut)
        #expect(fake.restoreSessionCallCount == 0)
    }

    @Test func resetReturnsToLoggedOut() async {
        let sm = AuthStateMachine(client: FakePhotosCore())
        sm.markExpired()
        #expect(sm.phase == .expired)
        sm.reset()
        #expect(sm.phase == .loggedOut)
    }
}
