import Foundation
import PhotosCore

/// Maps `CoreError` (the Rust core's error type, crossing the FFI boundary
/// verbatim) to strings and flags the UI can show directly.
///
/// The core's `message`/`api` payloads are already scrubbed of anything
/// sensitive before they cross the FFI boundary (see core/models), so it is
/// safe to interpolate them here; this extension only adds the human-facing
/// framing around them, it does not filter their contents.
extension CoreError {
    /// Human-facing message for the UI. Never leaks raw server text unfiltered.
    var userMessage: String {
        switch self {
        case .Auth(let message): return "Sign in failed. \(message)"
        case .OtpRequired: return "Enter your two-factor code to continue."
        case .Network(let message): return "Network problem. \(message)"
        case .Decode(let message): return "The server sent something we could not read. \(message)"
        case .UnexpectedResponse(let message): return "Unexpected response from the NAS. \(message)"
        case .WriteRefused: return "This action was blocked. The app is in read-only mode."
        case .Storage(let message): return "Local storage problem. \(message)"
        case .CapabilityUnavailable(let api): return "Your NAS does not offer a required feature: \(api)."
        }
    }

    /// Whether a retry could plausibly succeed without user action.
    var isRetryable: Bool {
        switch self {
        case .Network: return true
        default: return false
        }
    }
}
