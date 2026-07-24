import Foundation
import Testing
import PhotosCore
@testable import SynologyPhotos

struct PathMonitorTests {
    @Test func prefersLanWhenReachable() {
        let choice = HostSelector.choose(lanHost: "https://192.168.1.10:5001",
                                         tailscaleHost: "https://nas.tailnet.ts.net:5001", canReachLan: true)
        #expect(choice == .lan("https://192.168.1.10:5001"))
    }

    @Test func fallsBackToTailscaleWhenLanUnreachable() {
        let choice = HostSelector.choose(lanHost: "https://192.168.1.10:5001",
                                         tailscaleHost: "https://nas.tailnet.ts.net:5001", canReachLan: false)
        #expect(choice == .tailscale("https://nas.tailnet.ts.net:5001"))
    }

    @Test func staysOnLanWhenNoTailscaleConfigured() {
        let choice = HostSelector.choose(lanHost: "https://192.168.1.10:5001", tailscaleHost: nil, canReachLan: false)
        #expect(choice == .lan("https://192.168.1.10:5001"))
    }

    @Test func lanConnectionUsesSystemTrust() {
        let conn = HostSelector.connection(for: .lan("https://192.168.1.10:5001"), pinnedCertDer: Data([1, 2, 3]))
        #expect(conn.verifyTls == true)
        #expect(conn.pinnedCertDer == nil)
    }

    @Test func tailscaleConnectionPinsCert() {
        let conn = HostSelector.connection(for: .tailscale("https://nas.ts.net:5001"), pinnedCertDer: Data([9, 9]))
        #expect(conn.verifyTls == true)
        #expect(conn.pinnedCertDer == Data([9, 9]))
    }

    @Test func lanConnectionDefaultsInsecureToggleOff() {
        let conn = HostSelector.connection(for: .lan("https://192.168.1.10:5001"), pinnedCertDer: nil)
        #expect(conn.allowUntrustedTls == false)
    }

    @Test func connectionForwardsInsecureToggleWhenSet() {
        let conn = HostSelector.connection(
            for: .tailscale("https://nas.ts.net:5001"), pinnedCertDer: nil, allowUntrustedTls: true)
        #expect(conn.allowUntrustedTls == true)
    }
}
