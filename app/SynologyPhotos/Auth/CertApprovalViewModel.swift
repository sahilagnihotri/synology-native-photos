import Foundation
import PhotosCore

/// Trust-on-first-use state for the certificate approval prompt.
///
/// `idle` is the state before any host has been checked. `needsApproval`
/// carries the fetched `CertInfo` so the view can render the fingerprint
/// and subject for the user to compare/approve. `approved` means the DER
/// is now pinned in the Keychain and ready to use for `login`. `failed`
/// covers a fetch that could not complete at all (host unreachable, DNS
/// failure, etc), which is different from the user declining to approve
/// (there is no state for that: declining just leaves the flow at
/// `needsApproval`, since there is nothing further to do until the user
/// either approves or gives up).
enum CertTrustPhase: Equatable {
    case idle
    case checking
    case needsApproval(CertInfo)
    case approved(Data)
    case failed(message: String)
}

/// Drives the trust-on-first-use certificate approval flow for one host at
/// a time: on `checkHost`, load any already-pinned DER from the Keychain;
/// if there is none, fetch the server's live certificate over
/// `PhotosCore.fetchCertificate` and surface it for the user to approve.
///
/// Depends on `PhotosCoreProtocol` (not a concrete client) so tests can
/// drive every transition with `FakePhotosCore`, matching the pattern
/// `AuthStateMachine` already uses.
@MainActor
@Observable
final class CertApprovalViewModel {
    private let client: PhotosCoreProtocol
    var phase: CertTrustPhase = .idle

    init(client: PhotosCoreProtocol) {
        self.client = client
    }

    /// The DER to use as `Connection.pinnedCertDer` right now, if the flow
    /// has one ready (already pinned, or freshly approved this session).
    var pinnedCertDer: Data? {
        if case .approved(let der) = phase { return der }
        return nil
    }

    /// Checks `host`: if a pin is already stored, loads it straight into
    /// `.approved` with no network call. Otherwise fetches the live
    /// certificate and moves to `.needsApproval` for the user to review.
    ///
    /// Safe to call again for a different host; each call replaces `phase`
    /// from scratch, there is no per-host history kept beyond what is in
    /// the Keychain.
    func checkHost(_ host: String) async {
        if let stored = (try? KeychainCertPin.load(host: host)) ?? nil {
            phase = .approved(stored)
            return
        }
        phase = .checking
        do {
            let info = try await client.fetchCertificate(host: host)
            phase = .needsApproval(info)
        } catch let error as CoreError {
            phase = .failed(message: error.userMessage)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    /// Approves whatever certificate is currently pending in
    /// `.needsApproval`, pinning its DER to the Keychain for `host` and
    /// moving to `.approved`. A no-op (no state change) if `phase` is not
    /// currently `.needsApproval`, so a stray extra tap on the approve
    /// button can't do anything surprising.
    func approve(host: String) {
        guard case .needsApproval(let info) = phase else { return }
        try? KeychainCertPin.save(der: info.der, host: host)
        phase = .approved(info.der)
    }

    /// Forgets the pin for `host`, if any, and returns to `.idle` so the
    /// next `checkHost` re-runs the full TOFU fetch-and-approve flow. Used
    /// when the user suspects the pinned certificate is no longer right
    /// (e.g. the NAS's certificate legitimately rotated) rather than
    /// leaving them stuck unable to connect at all.
    func forgetPin(host: String) {
        try? KeychainCertPin.clear(host: host)
        phase = .idle
    }
}
