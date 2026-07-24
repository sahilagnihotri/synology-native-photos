import SwiftUI
import PhotosCore

/// Where this app run's local index (GRDB/SQLite) and on-disk thumbnail/temp
/// cache live. Both are per-machine, never synced anywhere: Application
/// Support for the durable local index, Caches for data the OS is free to
/// purge under disk pressure and this app can always regenerate from the NAS.
private struct AppPaths {
    let dbDir: URL
    let cacheDir: URL

    static func standard() -> AppPaths {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SynologyNativePhotos", isDirectory: true)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SynologyNativePhotos", isDirectory: true)
        return AppPaths(
            dbDir: appSupport.appendingPathComponent("db", isDirectory: true),
            cacheDir: caches.appendingPathComponent("cache", isDirectory: true))
    }

    /// Creates both directories if missing. Throws rather than silently
    /// continuing: a `PhotosCore` opened against a directory that could not
    /// be created would just fail its own open with a less legible error.
    func ensureDirectoriesExist() throws {
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}

/// What `SynologyPhotosApp` ends up showing: either the composed
/// `AppEnvironment` for a working core, or a message when the local store
/// could not be opened at all. Local-store-open failure (a corrupt SQLite
/// file, an unwritable directory, disk full) is not something the login
/// screen or a crash can meaningfully recover from, so it gets its own
/// terminal-looking screen instead of either.
private enum LaunchOutcome {
    case ready(AppEnvironment)
    case storeFailed(String)
}

/// Builds the real `AppEnvironment`, guarding `PhotosCore`'s constructor
/// (Task 32) with `CoreError` rather than trusting it to succeed. Failure
/// here means the local index/cache directories could not be opened at
/// all, e.g. disk full or a permissions problem; it must show an error
/// screen, not crash the app.
///
/// `host` is whatever this launch will use to scope the Keychain lookup
/// `AuthStateMachine.restore`/`attemptLogin` save under: the host of a
/// previously stored session if one exists (single-account app, see
/// `KeychainSID.loadMostRecentAccount`), or empty when there is none yet,
/// since `LoginView` always supplies its own host text field value on the
/// first-ever sign-in and `AppEnvironment.host` only matters for
/// `SignOutController`'s Keychain-clear step thereafter, which is guarded
/// on `AuthPhase.valid` (a session that itself only exists once a host has
/// been used).
@MainActor
private func makeLaunchOutcome() -> LaunchOutcome {
    let storedHost = (try? KeychainSID.loadMostRecentAccount())?.host ?? ""
    let paths = AppPaths.standard()
    do {
        try paths.ensureDirectoriesExist()
        let core = try PhotosCore(dbDir: paths.dbDir.path, cacheDir: paths.cacheDir.path)
        let env = AppEnvironment(core: core, accountCacheDir: paths.cacheDir, host: storedHost)
        return .ready(env)
    } catch let error as CoreError {
        return .storeFailed(error.userMessage)
    } catch {
        return .storeFailed(error.localizedDescription)
    }
}

@main
struct SynologyPhotosApp: App {
    private let outcome: LaunchOutcome

    init() {
        self.outcome = Self.makeOutcomeAndRestore()
    }

    /// Builds the environment and, on success, kicks off the launch
    /// restore-session attempt (`AuthStateMachine.restore`) so the app can
    /// land straight on the library without the user re-entering
    /// credentials, per the safety invariant that nothing here ever
    /// invents a session: `restore` itself decides `.valid` vs `.expired`
    /// vs `.loggedOut` from what is actually in the Keychain and confirmed
    /// against the NAS. With nothing stored (fresh install, or after a
    /// sign-out), `env.host` is empty and `restore` is skipped entirely;
    /// `RootRouter` reads `env.auth.phase` still at its initial
    /// `.loggedOut` and renders the login screen.
    @MainActor
    private static func makeOutcomeAndRestore() -> LaunchOutcome {
        let outcome = makeLaunchOutcome()
        let stored = (try? KeychainSID.loadMostRecentAccount()) ?? nil
        if case .ready(let env) = outcome, let stored {
            Task { @MainActor in
                await env.auth.restore(host: stored.host, username: stored.username)
            }
        }
        return outcome
    }

    var body: some Scene {
        WindowGroup {
            switch outcome {
            case .ready(let env):
                RootView(env: env).frame(minWidth: 900, minHeight: 600)
            case .storeFailed(let message):
                StoreFailedView(message: message).frame(minWidth: 480, minHeight: 320)
            }
        }
    }
}

/// Shown when the local store (`PhotosCore(dbDir:cacheDir:)`) could not be
/// opened at all. There is no retry action here on purpose: the failure
/// modes that reach this screen (disk full, permissions, corrupt file) are
/// not things a button press inside the same process run can fix.
private struct StoreFailedView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.red)
            Text("Could not open the local photo index").font(.title2).bold()
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityIdentifier("launch.storefailed")
    }
}
