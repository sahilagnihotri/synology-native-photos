import Foundation
import PhotosCore

/// Clean single-account sign-out / account-switch teardown.
///
/// This is deliberately narrow: one account signed in at a time (locked
/// decision, see the brief), so "sign out" always means "tear this one
/// account down completely and land back on the login screen." It is not an
/// account manager and never will store more than one account's material at
/// once.
///
/// Sequence, always run in this order regardless of failures along the way:
///  1. Server-side logout via the core (`PhotosCoreClient.signOut`), so the
///     NAS drops the session server-side too, not just locally.
///  2. Clear this account's Keychain-stored SID (`KeychainSID.clear`) so a
///     later launch's `AuthStateMachine.restore` has nothing to restore and
///     genuinely lands on the login screen rather than silently re-logging
///     the old account back in.
///  3. Wipe this account's on-disk cache directory (thumbnails, any other
///     per-account cached files) so a subsequent sign-in under a different
///     account can never read stale bytes left behind by this one.
///  4. Drop the in-memory thumbnail cache (`ThumbnailCache`) and run the
///     optional temp-cache teardown hook, so nothing from this account's
///     session lingers in memory either.
///  5. Reset `AuthStateMachine` back to `.loggedOut`, the state the login
///     view renders from.
///
/// This type never touches the NAS beyond the ordinary, reversible act of
/// logging the session out server-side (the same as closing a browser tab on
/// DSM); it never deletes, moves, or edits any asset on the NAS. All cache
/// wiping here is local-only.
///
/// Safety: every step is best-effort. A `PhotosCoreClient.signOut()` that
/// throws (already logged out, network drop, expired session) does not stop
/// the teardown, nor does a Keychain error, nor a filesystem error clearing
/// the cache directory. The point of "sign out" is to *always* land the app
/// back on the login screen for a clean account switch; a partial failure on
/// any one of these best-effort steps must never leave the user stuck mid
/// sign-out. `auth.reset()` always runs last and always succeeds, so
/// `signOut()` always ends in `.loggedOut` and is safe to call again
/// (idempotent) if the app is already signed out.
@MainActor
final class SignOutController {
    private let client: PhotosCoreClient
    private let auth: AuthStateMachine
    private let keychainHost: String
    private let keychainUsername: String
    private let accountCacheDir: URL
    private let thumbnailCache: ThumbnailCache
    private let clearTempCache: () async -> Void

    /// - Parameters:
    ///   - client: bridge to the core; asked to log the session out
    ///     server-side.
    ///   - auth: the app's single `AuthStateMachine`; reset to `.loggedOut`
    ///     once teardown completes.
    ///   - keychainHost: host the stored SID was saved under, matching what
    ///     `AuthStateMachine.attemptLogin`/`restore` used.
    ///   - keychainUsername: account whose Keychain entry is cleared.
    ///   - accountCacheDir: this account's on-disk cache directory (e.g. its
    ///     thumbnail cache folder). Its *contents* are removed; the
    ///     directory itself is left in place so callers don't need to
    ///     recreate it before the next sign-in.
    ///   - thumbnailCache: in-memory thumbnail cache to drop.
    ///   - clearTempCache: optional hook for clearing any other per-account
    ///     temp/scratch cache (e.g. a downloaded-original temp-file cache).
    ///     Defaults to a no-op so this controller has no hard dependency on
    ///     a temp-cache type; callers that have one pass its clear method
    ///     (e.g. `tempCache.clearAll`) here.
    init(
        client: PhotosCoreClient,
        auth: AuthStateMachine,
        keychainHost: String,
        keychainUsername: String,
        accountCacheDir: URL,
        thumbnailCache: ThumbnailCache,
        clearTempCache: @escaping () async -> Void = {}
    ) {
        self.client = client
        self.auth = auth
        self.keychainHost = keychainHost
        self.keychainUsername = keychainUsername
        self.accountCacheDir = accountCacheDir
        self.thumbnailCache = thumbnailCache
        self.clearTempCache = clearTempCache
    }

    /// Runs the full teardown sequence and lands on `.loggedOut`.
    ///
    /// Idempotent: calling this when already signed out (no live session,
    /// nothing in the Keychain, an empty or missing cache directory) is not
    /// an error, every step degrades to a no-op, and the phase is still
    /// `.loggedOut` afterward.
    func signOut() async {
        // 1. Server-side logout. Best-effort: an already-expired session or
        // a dropped connection must not block the rest of the teardown.
        try? await client.signOut()

        // 2. Drop the stored SID so a later restore has nothing to pick up.
        try? KeychainSID.clear(host: keychainHost, username: keychainUsername)

        // 3. Wipe this account's on-disk cache directory contents. Missing
        // directory (nothing to clear) or a per-item removal failure both
        // fall through silently; whatever can be removed is removed.
        if let items = try? FileManager.default.contentsOfDirectory(
            at: accountCacheDir, includingPropertiesForKeys: nil
        ) {
            for item in items {
                try? FileManager.default.removeItem(at: item)
            }
        }

        // 4. Drop in-memory caches for this account.
        await thumbnailCache.invalidate(assetId: -1)
        await clearTempCache()

        // 5. Always land back on the login screen, even if every step above
        // failed. This must never leave the user stuck mid sign-out.
        auth.reset()
    }
}
