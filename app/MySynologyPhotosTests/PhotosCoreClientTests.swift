import Testing
import PhotosCore
@testable import MySynologyPhotos

struct PhotosCoreClientTests {
    @Test func clientForwardsLogin() async throws {
        let fake = FakePhotosCore()
        fake.loginResult = .success(Session(sid: "S", synoToken: "T", username: "photo", deviceDid: nil))
        let client = PhotosCoreClient(core: fake)
        let conn = Connection(host: "https://h:5001", verifyTls: true, pinnedCertDer: nil, allowUntrustedTls: false)
        let s = try await client.login(connection: conn, username: "photo", password: "pw", otpCode: "123456", deviceToken: nil)
        #expect(s.synoToken == "T")
        #expect(fake.lastOtpCode == .some(.some("123456")))
    }

    @Test func otpRequiredMapsToPrompt() {
        #expect(CoreError.OtpRequired.userMessage.localizedCaseInsensitiveContains("code"))
        #expect(CoreError.OtpRequired.isRetryable == false)
    }

    @Test func networkErrorIsRetryable() {
        let e = CoreError.Network(message: "timeout")
        #expect(e.isRetryable == true)
        #expect(e.userMessage.localizedCaseInsensitiveContains("network"))
    }

    @Test func writeRefusedHasSafeMessage() {
        #expect(CoreError.WriteRefused.userMessage.localizedCaseInsensitiveContains("read-only"))
    }
}
