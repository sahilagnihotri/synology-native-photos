import Foundation
import PhotosCore

/// Reads the Rust core version over UniFFI. Defined at file scope, where the
/// free `coreVersion()` function is not shadowed. Referencing it inside
/// `AboutInfo` is impossible without this: `PhotosCore` names the exported
/// core type (not just the module), so `PhotosCore.coreVersion()` resolves
/// to that type, and the bare `coreVersion` inside the type resolves to the
/// stored property. This helper sidesteps both.
private func readCoreVersion() -> String { coreVersion() }

/// Read-only snapshot of the version facts shown in the About window.
///
/// A pure value type on purpose: it can be built and unit-tested without a
/// running app. The memberwise initializer lets tests pin every field to a
/// known value and assert the formatting, while `current` reads the live
/// sources (the app bundle, the build-time generated `GitVersion.shortSHA`,
/// and the Rust core version over UniFFI).
struct AboutInfo: Equatable {
    /// CFBundleShortVersionString, e.g. "1.0".
    let appVersion: String
    /// CFBundleVersion, e.g. "1".
    let build: String
    /// Short git SHA the executable was built from, e.g. "2c58b22", or
    /// "unknown" when the build happened outside a git checkout.
    let gitCommit: String
    /// The Rust `photoscore` crate version, read over the UniFFI boundary.
    let coreVersion: String
    /// The key Synology Web API versions this build requests.
    let apiVersions: [ApiVersion]

    /// One Synology API and the version the app sends for it. `id` is the
    /// API name so SwiftUI `ForEach` has a stable identity without a UUID.
    struct ApiVersion: Equatable, Identifiable {
        let name: String
        let version: String
        var id: String { name }
    }

    /// "1.0 (1)" style, matching the standard macOS About panel.
    var versionLine: String {
        "\(appVersion) (\(build))"
    }

    /// The Synology API versions this build requests, shown in the About
    /// window. These are the "version the app sends" values; the advertised
    /// ranges on the NAS and the exact code call sites are documented in
    /// documentation/synology-api-versions.md, which is the source of truth.
    /// Keep this list in sync with that file when a pinned version changes.
    static let knownApiVersions: [ApiVersion] = [
        ApiVersion(name: "SYNO.API.Auth", version: "3"),
        ApiVersion(name: "SYNO.API.Info", version: "1"),
        ApiVersion(name: "SYNO.Foto.Browse.Item", version: "1"),
        ApiVersion(name: "SYNO.Foto.Thumbnail", version: "2"),
        ApiVersion(name: "SYNO.Foto.Download", version: "2"),
        ApiVersion(name: "SYNO.Foto.Search.Search", version: "1"),
        ApiVersion(name: "SYNO.Foto.Search.Filter", version: "1"),
    ]

    /// Builds the live snapshot. `gitCommit` and `coreVersionProvider` are
    /// injectable so tests can pin them; both default to the real sources.
    static func current(
        bundle: Bundle = .main,
        gitCommit: String = GitVersion.shortSHA,
        coreVersionProvider: () -> String = readCoreVersion
    ) -> AboutInfo {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return AboutInfo(
            appVersion: short ?? "unknown",
            build: build ?? "unknown",
            gitCommit: gitCommit,
            coreVersion: coreVersionProvider(),
            apiVersions: knownApiVersions)
    }
}
