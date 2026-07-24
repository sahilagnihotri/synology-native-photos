import Foundation
import Network
import PhotosCore

/// Coarse network reachability as observed by the Network framework.
/// `unknown` is the initial state before the monitor has reported anything.
enum Reachability: Equatable {
    case unknown
    case offline
    case online
}

/// The host the app has decided to talk to, tagged by which network it is
/// reachable over. Carried separately from `Connection` because the choice
/// of host and the TLS trust policy for that host are two different concerns
/// (see `HostSelector.connection(for:pinnedCertDer:)`).
enum PreferredHost: Equatable {
    case lan(String)
    case tailscale(String)
}

/// Watches system network path changes and republishes them as a simple
/// three-state `Reachability` for the rest of the app to observe.
///
/// This only reports whether the device currently has a usable network path
/// (Wi-Fi, Ethernet, or otherwise) satisfied by the OS; it does not attempt to
/// reach the NAS itself. Actual LAN-vs-Tailscale host selection is
/// `HostSelector`'s job, driven by whatever reachability probe the caller
/// wires up.
@MainActor
@Observable
final class PathMonitor {
    var reachability: Reachability = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.synologynativephotos.pathmonitor")

    /// Starts observing path updates. Safe to call once per instance; the
    /// underlying `NWPathMonitor` is started on a private background queue,
    /// and every update is hopped back onto the main actor before mutating
    /// `reachability` so `@Observable` invalidation happens on the main thread.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let updated: Reachability = path.status == .satisfied ? .online : .offline
            Task { @MainActor in
                self?.reachability = updated
            }
        }
        monitor.start(queue: queue)
    }

    /// Stops observing path updates. Safe to call even if `start()` was
    /// never called, and safe to call more than once.
    func stop() {
        monitor.cancel()
    }
}

/// Chooses LAN-first, Tailscale fallback, and builds the matching
/// `Connection` with the correct TLS trust policy for whichever host wins.
///
/// TLS is never globally disabled (contract 2.6). The NAS's LAN address is a
/// bare IP that will never match the public Let's Encrypt certificate issued
/// for the DDNS name, so LAN connections rely on system trust and simply omit
/// any pinned cert. The Tailscale hostname is the one place a pinned
/// certificate is actually needed and applied, with TLS verification still on.
struct HostSelector {
    /// Picks LAN when it is reachable; otherwise falls back to the Tailscale
    /// host if one is configured; otherwise stays on LAN (there is nothing
    /// else to fall back to, and returning the LAN host lets the normal
    /// connection-failure path surface the problem rather than silently
    /// swallowing the missing Tailscale configuration).
    static func choose(lanHost: String, tailscaleHost: String?, canReachLan: Bool) -> PreferredHost {
        if canReachLan {
            return .lan(lanHost)
        }
        if let tailscaleHost {
            return .tailscale(tailscaleHost)
        }
        return .lan(lanHost)
    }

    /// Builds the `Connection` for `host`, applying the cert-trust rule:
    /// - LAN: system trust. `pinnedCertDer` is always discarded (set to nil)
    ///   even if the caller supplies one, because a LAN IP never matches the
    ///   NAS's public certificate and pinning would only break the connection.
    /// - Tailscale: the supplied DER is pinned so the Tailscale hostname's
    ///   certificate can be trusted. TLS verification stays on either way;
    ///   this never disables validation, it only supplies an additional
    ///   trust anchor for the one host that needs it.
    static func connection(for host: PreferredHost, pinnedCertDer: Data?) -> Connection {
        switch host {
        case .lan(let h):
            return Connection(host: h, verifyTls: true, pinnedCertDer: nil)
        case .tailscale(let h):
            return Connection(host: h, verifyTls: true, pinnedCertDer: pinnedCertDer)
        }
    }
}
