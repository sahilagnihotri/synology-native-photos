import Testing
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct LoginViewModelTests {
    @Test func syncShowsOtpFieldOnNeedsOtp() {
        let m = LoginFormModel(auth: AuthStateMachine(client: FakePhotosCore()))
        m.sync(with: .needsOtp(username: "photo"))
        #expect(m.showOtp == true)
        #expect(m.errorText?.localizedCaseInsensitiveContains("code") == true)
    }

    @Test func syncShowsErrorOnInvalid() {
        let m = LoginFormModel(auth: AuthStateMachine(client: FakePhotosCore()))
        m.sync(with: .invalid(message: "bad password"))
        #expect(m.errorText == "bad password")
        #expect(m.showOtp == false)
    }

    @Test func syncClearsErrorOnValid() {
        let m = LoginFormModel(auth: AuthStateMachine(client: FakePhotosCore()))
        m.errorText = "stale"
        m.sync(with: .valid(Session(sid: "S", synoToken: nil, username: "photo", deviceDid: nil)))
        #expect(m.errorText == nil)
    }

    @Test func submitForwardsOtpCode() async {
        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S", synoToken: nil, username: "photo", deviceDid: nil))
        let auth = AuthStateMachine(client: fake)
        let m = LoginFormModel(auth: auth)
        m.host = "https://h:5001"; m.username = "photo"; m.password = "pw"; m.showOtp = true; m.otpCode = "111222"
        await m.submit()
        #expect(fake.lastOtpCode == .some(.some("111222")))
    }
}
