import Testing
import PhotosCore
@testable import SynologyPhotos

struct KeychainSIDTests {
    private let host = "https://kc-test.local:5001"
    private let user = "kctestuser"
    private func cleanup() { try? KeychainSID.clear(host: host, username: user) }

    @Test func saveThenLoadRoundTrips() throws {
        cleanup(); defer { cleanup() }
        let s = Session(sid: "SID-ABC", synoToken: "TOK", username: user, deviceDid: "DID9")
        try KeychainSID.save(s, host: host)
        let loaded = try KeychainSID.load(host: host, username: user)
        #expect(loaded?.sid == "SID-ABC")
        #expect(loaded?.synoToken == "TOK")
        #expect(loaded?.deviceDid == "DID9")
        #expect(loaded?.host == host)
    }

    @Test func saveOverwritesExisting() throws {
        cleanup(); defer { cleanup() }
        try KeychainSID.save(Session(sid: "OLD", synoToken: nil, username: user, deviceDid: nil), host: host)
        try KeychainSID.save(Session(sid: "NEW", synoToken: nil, username: user, deviceDid: nil), host: host)
        #expect(try KeychainSID.load(host: host, username: user)?.sid == "NEW")
    }

    @Test func clearRemovesEntry() throws {
        try KeychainSID.save(Session(sid: "X", synoToken: nil, username: user, deviceDid: nil), host: host)
        try KeychainSID.clear(host: host, username: user)
        #expect(try KeychainSID.load(host: host, username: user) == nil)
    }

    @Test func loadMissingReturnsNil() throws {
        cleanup()
        #expect(try KeychainSID.load(host: host, username: "nobody") == nil)
    }
}
