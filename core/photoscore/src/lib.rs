//! The UniFFI boundary crate exposing PhotosCore to Swift.

use std::sync::{Arc, Mutex};

use models::{
    Album, ApiCapability, Asset, CertInfo, Connection, CoreError, CrawlProgress, Session, SessionState, Space,
    ThumbnailData, ThumbnailSize,
};
use persistence::Store;
use sync_engine::crawl::{Crawler, ProgressSink};
use sync_engine::delta::DeltaReconciler;
use sync_engine::{AssetPage, PageSource};
use synology_api::Transport;

uniffi::setup_scaffolding!("photoscore");

/// Trivial cross-boundary smoke function. Returns the core crate version.
/// Proves Swift can call into Rust over UniFFI before the full PhotosCore lands.
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

/// Implemented on the Swift side; called from Rust during crawl_space.
#[uniffi::export(callback_interface)]
pub trait FfiCrawlObserver: Send + Sync {
    fn on_progress(&self, progress: CrawlProgress);
}

/// Adapts synology-api's `list_items` onto the sync-engine `PageSource`
/// trait for one fixed transport/session/API-version triple. sync-engine
/// only ever sees this trait, never the HTTP client directly.
struct ApiPageSource {
    transport: Transport,
    sid: String,
    version: u32,
    syno_token: Option<String>,
}

#[async_trait::async_trait]
impl PageSource for ApiPageSource {
    async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
        let assets = synology_api::list_items(
            &self.transport,
            &self.sid,
            space,
            offset,
            limit,
            self.version,
            self.syno_token.as_deref(),
        )
        .await?;
        // The Browse.Item list does not return a grand total on every DSM build; when
        // absent we treat a short page as the end. Report the running count as total so
        // the barrier still flips on the final short page (offset >= total holds).
        let total = if (assets.len() as u32) < limit {
            (offset as u64) + assets.len() as u64
        } else {
            (offset as u64) + limit as u64 + 1
        };
        Ok(AssetPage { assets, total })
    }
}

/// Adapts the UniFFI callback interface onto sync-engine's internal
/// `ProgressSink`, so sync-engine stays free of UniFFI concerns.
struct ObserverSink {
    observer: Box<dyn FfiCrawlObserver>,
}
impl ProgressSink for ObserverSink {
    fn emit(&self, progress: CrawlProgress) {
        self.observer.on_progress(progress);
    }
}

/// Post-login connection state held inside the core.
struct Live {
    transport: Transport,
    session: Session,
    connection: Connection,
    capabilities: Vec<ApiCapability>,
}

/// The single UniFFI-exported facade. Swift holds one instance per app run.
///
/// `Store` wraps a `rusqlite::Connection`, whose internal statement cache uses
/// a `RefCell` and so is not `Sync`. UniFFI objects are shared across threads
/// as `Arc<Self>`, so `store` is held behind a `Mutex` (like `live`) rather
/// than bare, to satisfy `Send + Sync` and to make the cross-thread access
/// pattern explicit rather than accidental.
///
/// Because `Store` is not `Sync`, `&Store` is not `Send` either, so a
/// `Crawler`/`DeltaReconciler` borrowing it can never be held across an
/// `.await` inside a future the tokio `async_runtime` binding requires to be
/// `Send` (uniffi's exported async methods must return a `Send` future).
/// `crawl_space`/`reconcile_delta` route around this by taking the `Store`
/// *out* of the mutex by value and moving it onto a dedicated blocking
/// thread (`spawn_blocking`), where the whole crawl - including its
/// internal network awaits - runs synchronously via `Handle::block_on`; the
/// owned `Store` is moved back into the mutex once the blocking task
/// returns, even if the crawl itself panicked partway through (the panic is
/// caught on the blocking thread and turned into an ordinary error, see
/// `run_with_store`), so a single bad crawl can never leave the core
/// permanently unusable. The mutex guard itself is only ever held for the
/// instant of the swap, never across any `.await`.
#[derive(uniffi::Object)]
pub struct PhotosCore {
    /// `Option` so `run_with_store` can `take()` the owned `Store` out for
    /// the duration of a blocking-thread crawl and put it back afterward,
    /// without ever holding the mutex guard itself across an `.await`.
    /// Empty (`None`) only for the brief window while a crawl/reconcile is
    /// actually running on its blocking thread; every other method observes
    /// `Some`.
    store: Mutex<Option<Store>>,
    cache_dir: String,
    live: Mutex<Option<Live>>,
}

#[uniffi::export(async_runtime = "tokio")]
impl PhotosCore {
    /// Construct with a local DB directory. Opens/creates SQLite + runs migrations.
    #[uniffi::constructor]
    pub fn new(db_dir: String, cache_dir: String) -> Result<Arc<Self>, CoreError> {
        let db_path = std::path::Path::new(&db_dir).join("photos.sqlite");
        let store = Store::open_at(&db_path)?;
        Ok(Arc::new(PhotosCore { store: Mutex::new(Some(store)), cache_dir, live: Mutex::new(None) }))
    }

    /// Log in against `connection` with the given credentials.
    ///
    /// `otp_code` and `device_token` are forwarded to `synology_api::login`
    /// untouched:
    /// - `otp_code = None` omits the param entirely, so an account with 2FA
    ///   enabled answers with `CoreError::OtpRequired` (see
    ///   `synology_api::auth`), which the Swift UI is expected to catch,
    ///   prompt for a code, and retry with `otp_code = Some(code)`.
    /// - `device_token` should be the value previously returned on
    ///   `Session.device_did` from an earlier login on this host+account
    ///   (the caller/UI is responsible for persisting it, e.g. Keychain).
    ///   Passing it lets a trusted device skip OTP; DSM rejecting a stale
    ///   token falls back to the same `CoreError::OtpRequired` as no token
    ///   at all (fail-closed, see `synology_api::auth` doc comment).
    ///
    /// On success, replaces any previously held `Live` state with a fresh
    /// transport/session pair (capability probe deferred to first use, so
    /// login itself stays a single round trip). The returned `Session`
    /// carries any device token DSM minted/confirmed in `device_did`; the
    /// caller is expected to persist it for a future `device_token` login.
    pub async fn login(
        &self,
        connection: Connection,
        username: String,
        password: String,
        otp_code: Option<String>,
        device_token: Option<String>,
    ) -> Result<Session, CoreError> {
        let transport = Transport::new(&connection)?;
        let session = synology_api::login(&transport, &username, &password, otp_code.as_deref(), device_token.as_deref()).await?;
        let mut guard = self.live.lock().expect("live mutex poisoned");
        *guard = Some(Live {
            transport,
            session: session.clone(),
            connection,
            capabilities: Vec::new(),
        });
        Ok(session)
    }

    /// Fetches the TLS certificate presented by `host` for trust-on-first-use
    /// approval, without ever trusting it for a real request (see
    /// `synology_api::fetch_server_cert_der` for exactly what is and is not
    /// relaxed during this one-shot probe).
    ///
    /// This is a standalone, session-free call: it can be made before
    /// `login` (indeed, that is the intended flow) to let the UI show the
    /// user the server's fingerprint + subject and get their approval before
    /// ever sending credentials anywhere. Approving means storing the
    /// returned `CertInfo.der` (Keychain or app config) and passing it as
    /// `Connection.pinned_cert_der` on the `Connection` used for `login`.
    pub async fn fetch_certificate(&self, host: String) -> Result<CertInfo, CoreError> {
        synology_api::fetch_server_cert_der(&host).await
    }

    /// Rebuild `Live` state from a previously stored `Session` (e.g. loaded
    /// from the Keychain) without re-running the login handshake.
    ///
    /// Validates the session with a cheap authed capability probe
    /// (`SYNO.API.Info`): a probe failure that maps to `CoreError::Auth` or
    /// `CoreError::OtpRequired` means the stored session is no longer
    /// accepted by DSM, so this reports `SessionState::Expired` rather than
    /// an error the caller has to handle as failure - the UI can react by
    /// sending the user back through `login`. Any other probe error (e.g.
    /// network failure) is fail-closed and propagated as-is.
    pub async fn restore_session(
        &self,
        connection: Connection,
        session: Session,
    ) -> Result<SessionState, CoreError> {
        let transport = Transport::new(&connection)?;
        match synology_api::probe_capabilities(&transport).await {
            Ok(caps) => {
                let mut guard = self.live.lock().expect("live mutex poisoned");
                *guard = Some(Live { transport, session, connection, capabilities: caps });
                Ok(SessionState::Valid)
            }
            Err(CoreError::Auth { .. }) | Err(CoreError::OtpRequired) => Ok(SessionState::Expired),
            Err(other) => Err(other),
        }
    }

    /// Sign out: best-effort server-side logout, then unconditionally drop
    /// `Live` and clear the per-account thumbnail cache dir contents.
    ///
    /// Idempotent by construction: if no session is held, `taken` is `None`,
    /// the server logout call is skipped, and clearing an already-empty (or
    /// absent) cache dir is a no-op, so calling `sign_out` with nothing to
    /// sign out of always succeeds.
    pub async fn sign_out(&self) -> Result<(), CoreError> {
        let taken = {
            let mut guard = self.live.lock().expect("live mutex poisoned");
            guard.take()
        };
        if let Some(live) = taken {
            let _ = synology_api::logout(&live.transport, &live.session.sid).await;
        }
        // Clear the per-account thumbnail cache dir contents (read-only teardown).
        let thumbs = std::path::Path::new(&self.cache_dir).join("thumbs");
        if thumbs.exists() {
            let _ = std::fs::remove_dir_all(&thumbs);
        }
        Ok(())
    }

    /// Probe `SYNO.API.Info` over the live session and cache the discovered
    /// capability set into `Live.capabilities` for later version pinning
    /// (Tasks 36/37 read it via `pin_version`).
    ///
    /// Fails closed with `CoreError::Auth` if no session is held rather than
    /// panicking: a caller that never logged in gets an error to handle, not
    /// a crash.
    ///
    /// A fresh `Transport` is rebuilt from the stored `Connection` inside the
    /// lock, then the lock is dropped before the `.await` so the std `Mutex`
    /// guard is never held across an await point.
    pub async fn probe_capabilities(&self) -> Result<Vec<ApiCapability>, CoreError> {
        let transport = {
            let guard = self.live.lock().expect("live mutex poisoned");
            match guard.as_ref() {
                Some(live) => Transport::new(&live.connection)?,
                None => return Err(CoreError::Auth { message: "not logged in".into() }),
            }
        };
        let caps = synology_api::probe_capabilities(&transport).await?;
        if let Some(live) = self.live.lock().expect("live mutex poisoned").as_mut() {
            live.capabilities = caps.clone();
        }
        Ok(caps)
    }

    /// Drives a resumable full crawl of `space` to completion (or until
    /// interrupted by an error), reporting `CrawlProgress` to `observer`
    /// after every page via `ObserverSink`.
    ///
    /// Requires a live session: fails closed with `CoreError::Auth` if
    /// `login`/`restore_session` has not populated `Live`. `page_source_for`
    /// takes the `live` std `Mutex` guard only long enough to clone the
    /// transport/sid/version it needs and drops it before returning, well
    /// before any `.await` here runs.
    ///
    /// The crawl itself runs via `run_with_store` (see its doc comment):
    /// the `store` mutex is only ever locked for the instant needed to move
    /// the `Store` out and back in, never across an `.await`.
    pub async fn crawl_space(
        &self,
        space: Space,
        observer: Box<dyn FfiCrawlObserver>,
    ) -> Result<CrawlProgress, CoreError> {
        let source = self.page_source_for(space)?;
        let sink = ObserverSink { observer };
        self.run_with_store(move |store| {
            Box::pin(async move {
                let crawler = Crawler::new(store, &source, 200);
                crawler.crawl_space(space, &sink).await
            })
        })
        .await
    }

    /// Runs delta reconciliation (new/changed/deleted) for `space` against
    /// the live session. Same auth and lock discipline as `crawl_space`.
    pub async fn reconcile_delta(&self, space: Space) -> Result<CrawlProgress, CoreError> {
        let source = self.page_source_for(space)?;
        self.run_with_store(move |store| {
            Box::pin(async move {
                let reconciler = DeltaReconciler::new(store, &source, 200);
                reconciler.reconcile(space).await
            })
        })
        .await
    }

    /// Reads back the persisted crawl progress for `space` with no network
    /// access at all. A plain sync `fn` (per the brief's signature); it
    /// takes the `store` std `Mutex` only for the duration of the read, so
    /// it can never be the source of contention with a concurrent crawl -
    /// it simply waits its turn like any other `Mutex` user.
    pub fn crawl_progress(&self, space: Space) -> Result<CrawlProgress, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.crawl_progress(space)
    }

    /// Local-only asset count for `space`; used by tests and diagnostics.
    pub fn asset_count(&self, space: Space) -> Result<u64, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.asset_count(space)
    }

    /// Windowed local read of assets in `space`, newest-first, for the grid's
    /// scrolling. No network access at all: this is a plain sync `fn` that
    /// only ever locks `store` for the duration of the read, so it can never
    /// block on (or be blocked by) a concurrent crawl for longer than that
    /// crawl needs to swap the `Store` back in.
    pub fn fetch_assets(&self, space: Space, offset: u32, limit: u32) -> Result<Vec<Asset>, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.fetch_assets(space, offset, limit)
    }

    /// Local read of every album in `space`, ordered by name. No network
    /// access; same lock discipline as `fetch_assets`/`asset_count`.
    pub fn fetch_albums(&self, space: Space) -> Result<Vec<Album>, CoreError> {
        let guard = self.store.lock().expect("store mutex poisoned");
        let store = guard.as_ref().ok_or_else(store_busy_err)?;
        store.fetch_albums(space)
    }

    /// Fetches a thumbnail for `asset_id` at `size`, served from a
    /// composite-key on-disk cache whenever possible.
    ///
    /// The cache path is `{cache_dir}/thumbs/{hex_digest}.jpg`, where
    /// `hex_digest` is a hash of `(space, asset_id, size, cache_key)`. Hashing
    /// the composite key rather than interpolating any of its parts (in
    /// particular the NAS-supplied `cache_key`) directly into the filename
    /// means the filename is always a fixed-length hex string: no path
    /// separator, no `..`, no length blowup can ever reach the filesystem,
    /// even if `cache_key` were ever malformed or unexpectedly large. A
    /// changed `cache_key` still hashes to a different digest, so this keeps
    /// the same invalidation property as before: whenever the server-side
    /// asset changes and the NAS mints a new cache_key, the new call produces
    /// a different path and can never be served a stale file.
    ///
    /// On a cache hit, this returns entirely from disk with no network
    /// access. On a miss, `live` is locked only long enough to clone the
    /// transport/sid/version triple it needs; the guard is dropped before the
    /// `fetch_thumbnail` `.await`, matching the discipline used by
    /// `page_source_for`/`crawl_space` elsewhere in this file. The fetched
    /// bytes are written atomically (temp file in the same directory, then
    /// renamed into place) so a concurrent reader/writer or a symlink planted
    /// at the target path can never observe a partial write or be written
    /// through.
    ///
    /// Fails closed with `CoreError::Auth` if no session is held.
    pub async fn thumbnail(
        &self,
        space: Space,
        asset_id: i64,
        cache_key: String,
        size: ThumbnailSize,
    ) -> Result<ThumbnailData, CoreError> {
        let dir = std::path::Path::new(&self.cache_dir).join("thumbs");
        let path = dir.join(format!("{}.jpg", cache_digest(&[space_tag(space), &asset_id.to_string(), size_tag(size), &cache_key])));
        if path.exists() {
            let bytes = std::fs::read(&path).map_err(|e| CoreError::Storage { message: e.to_string() })?;
            return Ok(ThumbnailData { cached_path: path.to_string_lossy().into(), bytes });
        }

        let (transport, sid, version, syno_token) = {
            let guard = self.live.lock().expect("live mutex poisoned");
            let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
            let api = match space {
                Space::Personal => "SYNO.Foto.Thumbnail",
                Space::Shared => "SYNO.FotoTeam.Thumbnail",
            };
            let version = synology_api::pin_version(&live.capabilities, api, 2).unwrap_or(2);
            (Transport::new(&live.connection)?, live.session.sid.clone(), version, live.session.syno_token.clone())
        };

        let bytes = synology_api::fetch_thumbnail(
            &transport,
            &sid,
            space,
            asset_id,
            &cache_key,
            size,
            version,
            syno_token.as_deref(),
        )
        .await?;
        write_cache_file_atomically(&dir, &path, &bytes)?;
        Ok(ThumbnailData { cached_path: path.to_string_lossy().into(), bytes })
    }

    /// Downloads the original full-resolution bytes for `asset_id` to a
    /// temp file and returns its absolute path. Read-only: never writes
    /// anything back to the NAS.
    ///
    /// Same lock discipline as `thumbnail`: `live` is locked only long enough
    /// to clone the transport/sid/version triple, then dropped before the
    /// network `.await`. The destination filename is a hash of
    /// `(asset_id, cache_key)` for the same path-safety reason as `thumbnail`
    /// (the NAS-supplied `cache_key` never appears literally in a path), and
    /// the bytes are written atomically (temp file, then renamed into place).
    ///
    /// Fails closed with `CoreError::Auth` if no session is held.
    pub async fn download_original(
        &self,
        space: Space,
        asset_id: i64,
        cache_key: String,
    ) -> Result<String, CoreError> {
        let (transport, sid, version, syno_token) = {
            let guard = self.live.lock().expect("live mutex poisoned");
            let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
            let api = match space {
                Space::Personal => "SYNO.Foto.Download",
                Space::Shared => "SYNO.FotoTeam.Download",
            };
            let version = synology_api::pin_version(&live.capabilities, api, 2).unwrap_or(2);
            (Transport::new(&live.connection)?, live.session.sid.clone(), version, live.session.syno_token.clone())
        };

        let bytes = synology_api::download_original(
            &transport,
            &sid,
            space,
            asset_id,
            &cache_key,
            version,
            syno_token.as_deref(),
        )
        .await?;
        let dir = std::env::temp_dir();
        let tmp = dir.join(format!("syno-orig-{}", cache_digest(&[&asset_id.to_string(), &cache_key])));
        write_cache_file_atomically(&dir, &tmp, &bytes)?;
        Ok(tmp.to_string_lossy().into())
    }
}

/// Maps a `ThumbnailSize` to its stable path-tag string. No injection
/// surface: values come from a closed enum, never from NAS-supplied data.
fn size_tag(size: ThumbnailSize) -> &'static str {
    match size {
        ThumbnailSize::Sm => "sm",
        ThumbnailSize::M => "m",
        ThumbnailSize::Xl => "xl",
    }
}

/// Maps a `Space` to its stable path-tag string. No injection surface: values
/// come from a closed enum, never from NAS-supplied data.
fn space_tag(space: Space) -> &'static str {
    match space {
        Space::Personal => "personal",
        Space::Shared => "shared",
    }
}

/// Hashes a composite cache key (any number of string parts, e.g. `space`,
/// `asset_id`, `size`, `cache_key`) into a fixed-length hex digest suitable
/// for use as a filename.
///
/// This is the sole defense against path traversal in the disk cache: none
/// of the input parts (in particular the NAS-supplied `cache_key`, which is
/// otherwise unsanitized) ever appear literally in the resulting path. A `/`,
/// a `..` segment, or an absurdly long value in any part changes the digest
/// but can never itself reach the filesystem, because the digest is always
/// exactly 16 lowercase hex characters. Two composite keys that differ in any
/// part hash to different digests (barring a hash collision), which
/// preserves the existing cache invalidation property: a changed `cache_key`
/// still produces a different cache path and is always treated as a miss.
///
/// Uses `std::collections::hash_map::DefaultHasher`, which is fine here: this
/// is a cache filename, not a cryptographic or adversarial-collision
/// context, and the parts are delimited (hashed one at a time with a
/// separator) so distinct part boundaries can't be confused with each other.
fn cache_digest(parts: &[&str]) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    for part in parts {
        part.hash(&mut hasher);
        0u8.hash(&mut hasher); // separator so ("ab","c") != ("a","bc")
    }
    format!("{:016x}", hasher.finish())
}

/// Writes `bytes` to `final_path` atomically: creates `dir` if missing,
/// writes to a freshly named temp file inside `dir`, then renames it into
/// place. `rename` within the same directory is atomic on macOS (and POSIX
/// generally), so any concurrent reader of `final_path` either sees the
/// complete old file or the complete new file, never a partial write.
///
/// This also removes the symlink/TOCTOU risk of writing straight to
/// `final_path`: the temp file is always a brand-new, uniquely named path (no
/// pre-existing file or symlink for `create_new` to follow), and `rename`
/// replaces whatever is at `final_path` wholesale rather than opening and
/// writing through it, so a symlink planted at `final_path` is atomically
/// swapped out rather than dereferenced and written into.
fn write_cache_file_atomically(dir: &std::path::Path, final_path: &std::path::Path, bytes: &[u8]) -> Result<(), CoreError> {
    std::fs::create_dir_all(dir).map_err(|e| CoreError::Storage { message: e.to_string() })?;
    let unique = format!(".tmp-{}-{}", std::process::id(), cache_digest(&[&std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos().to_string()]));
    let tmp_path = dir.join(unique);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp_path)
        .map_err(|e| CoreError::Storage { message: e.to_string() })?;
    use std::io::Write;
    let write_result = file.write_all(bytes).and_then(|_| file.sync_all());
    if let Err(e) = write_result {
        let _ = std::fs::remove_file(&tmp_path);
        return Err(CoreError::Storage { message: e.to_string() });
    }
    drop(file);
    std::fs::rename(&tmp_path, final_path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp_path);
        CoreError::Storage { message: e.to_string() }
    })
}

/// The `store` mutex briefly holds `None` only while a crawl/reconcile has
/// taken the `Store` out to run on its blocking thread. Any other caller
/// landing in that window gets a clear, fail-closed error rather than a
/// panic on `Option::unwrap`.
fn store_busy_err() -> CoreError {
    CoreError::Storage { message: "store busy: a crawl or reconcile is in progress".into() }
}

impl PhotosCore {
    /// Builds an `ApiPageSource` bound to the currently live session for
    /// `space`, pinning the browse-item API version from the cached
    /// capability set (falling back to `1` if capabilities were never
    /// probed). Locks `live` only long enough to clone what is needed; the
    /// guard is dropped before returning, well before any caller `.await`s
    /// the resulting source's `list_items`.
    fn page_source_for(&self, _space: Space) -> Result<ApiPageSource, CoreError> {
        let guard = self.live.lock().expect("live mutex poisoned");
        let live = guard.as_ref().ok_or(CoreError::Auth { message: "not logged in".into() })?;
        let version = synology_api::pin_version(&live.capabilities, "SYNO.Foto.Browse.Item", 1)
            .or_else(|_| synology_api::pin_version(&live.capabilities, "SYNO.FotoTeam.Browse.Item", 1))
            .unwrap_or(1);
        Ok(ApiPageSource {
            transport: Transport::new(&live.connection)?,
            sid: live.session.sid.clone(),
            version,
            syno_token: live.session.syno_token.clone(),
        })
    }

    /// Runs `work` (the sync-engine crawl or reconcile call) against an
    /// owned `Store` without ever holding the `store` mutex guard across an
    /// `.await`.
    ///
    /// `Store` wraps a `RefCell`-based rusqlite statement cache and so is
    /// not `Sync`, which means `&Store` is not `Send`. uniffi's
    /// `async_runtime = "tokio"` export requires every exported `async fn`
    /// to return a `Send` future, so a `Crawler`/`DeltaReconciler` borrowing
    /// `&Store` can never be held live across the `.await` inside that
    /// future - the compiler rejects it outright (confirmed while building
    /// this: holding a locked `&Store` across `crawler.crawl_space(..).await`
    /// fails with "future cannot be sent between threads safely" regardless
    /// of which mutex type guards it).
    ///
    /// The fix is to never let a `Store` borrow cross the outer async
    /// boundary at all: the `store` mutex is locked just long enough to
    /// `take()` the owned `Store` out (`Option<Store>` swap), the guard is
    /// dropped immediately, and the owned `Store` moves onto a dedicated
    /// blocking thread via `spawn_blocking`. There, `Handle::block_on` drives
    /// `work`'s future to completion synchronously - this is the documented,
    /// supported way to run async code from a blocking-pool thread, and it
    /// keeps the whole crawl (including its internal network awaits) on one
    /// thread so `&Store` never needs to be `Send`.
    ///
    /// Guarantee: after this function returns, `self.store` holds `Some` again,
    /// no matter how `work` finished, success, a normal `Err`, or a panic inside
    /// `work` itself. The blocking closure runs `work` behind `catch_unwind` and
    /// always hands the `Store` back in its return tuple, even when `work`
    /// panicked; a caught panic is converted into a `CoreError::Storage` here
    /// rather than being allowed to drop the `Store` on the panicking thread.
    /// So a panicking crawl surfaces as an ordinary error to the caller and
    /// the core stays usable for every call afterward - it never permanently
    /// bricks the store. The mutex is locked twice, once for the initial
    /// take and once for the final swap-back, never across an `.await`.
    async fn run_with_store<F>(&self, work: F) -> Result<CrawlProgress, CoreError>
    where
        F: for<'a> FnOnce(
                &'a Store,
            ) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<CrawlProgress, CoreError>> + 'a>>
            + Send
            + 'static,
    {
        let store = {
            let mut guard = self.store.lock().expect("store mutex poisoned");
            guard.take().ok_or_else(store_busy_err)?
        };

        let handle = tokio::runtime::Handle::current();
        let join = tokio::task::spawn_blocking(move || {
            // `store` stays owned in this outer scope for the whole call, so
            // it survives regardless of what happens inside `catch_unwind`.
            // Only a *reference* to it is captured by the inner closure, so
            // a panic there unwinds up to `catch_unwind` and stops - it never
            // drops `store` itself, because `store` was never moved into the
            // unwinding frame. We are only ever handing back a plain owned
            // value afterward, never inspecting any broken invariant of
            // shared state left behind by the panic, so asserting
            // unwind-safety on the borrow is sound even though `Store`
            // doesn't implement `UnwindSafe` itself (its `RefCell`-backed
            // statement cache is what disqualifies it).
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handle.block_on(work(&store))))
                .unwrap_or_else(|panic| {
                    let message = panic
                        .downcast_ref::<&str>()
                        .map(|s| s.to_string())
                        .or_else(|| panic.downcast_ref::<String>().cloned())
                        .unwrap_or_else(|| "non-string panic payload".to_string());
                    Err(CoreError::Storage { message: format!("crawl/reconcile task panicked: {message}") })
                });
            (store, result)
        })
        .await;

        match join {
            Ok((store, result)) => {
                let mut guard = self.store.lock().expect("store mutex poisoned");
                *guard = Some(store);
                result
            }
            // A panic inside `work` is already caught above and folded into
            // `result` alongside the recovered `Store`, so this arm is only
            // reached by a `JoinError` the blocking task itself never ran to
            // completion for (e.g. the runtime shutting down under it). The
            // `Store` was moved into that still-unresolved task and cannot be
            // recovered here; `store` stays `None` in this one remaining
            // case, which fails closed via `store_busy_err` on later calls.
            Err(e) => Err(CoreError::Storage { message: format!("crawl/reconcile task failed to join: {e}") }),
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn core_version_matches_cargo_pkg_version() {
        assert_eq!(crate::core_version(), env!("CARGO_PKG_VERSION"));
        assert_eq!(crate::core_version(), "0.1.0");
    }
}

#[cfg(test)]
mod core_tests {
    use super::*;

    #[test]
    fn new_opens_store() {
        let dir = std::env::temp_dir().join(format!("photoscore-new-{}", std::process::id()));
        let db = dir.join("db");
        let cache = dir.join("cache");
        std::fs::create_dir_all(&db).unwrap();
        std::fs::create_dir_all(&cache).unwrap();
        let _core = PhotosCore::new(db.to_string_lossy().into(), cache.to_string_lossy().into())
            .expect("core opens");
    }

    fn core_at(label: &str) -> Arc<PhotosCore> {
        let dir = std::env::temp_dir().join(format!("photoscore-{}-{}", label, std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into())
            .expect("core opens")
    }

    #[tokio::test]
    async fn login_stores_live_session() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-CORE","synotoken":"TK"}}"#)
            .create_async()
            .await;
        let core = core_at("login");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = core
            .login(conn, "photouser".into(), "pw".into(), Some("123456".into()), None)
            .await
            .expect("login ok");
        assert_eq!(session.sid, "SID-CORE");

        // The session is now held in `live`, so a second login (or any
        // authed call) would reuse it rather than starting from None.
        let guard = core.live.lock().unwrap();
        assert!(guard.is_some(), "login must populate Live");
        assert_eq!(guard.as_ref().unwrap().session.sid, "SID-CORE");
    }

    #[tokio::test]
    async fn login_without_otp_when_required_surfaces_otp_required() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":403}}"#)
            .create_async()
            .await;
        let core = core_at("login-otp");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let err = core
            .login(conn, "photouser".into(), "pw".into(), None, None)
            .await
            .unwrap_err();
        assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");

        // A failed login must not leave stale Live state behind.
        let guard = core.live.lock().unwrap();
        assert!(guard.is_none(), "failed login must not populate Live");
    }

    #[tokio::test]
    async fn restore_session_with_valid_probe_populates_live() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{}}"#)
            .create_async()
            .await;
        let core = core_at("restore-valid");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = Session {
            sid: "SID-RESTORE".into(),
            syno_token: None,
            username: "photouser".into(),
            device_did: None,
        };
        let state = core.restore_session(conn, session).await.expect("restore ok");
        assert!(matches!(state, SessionState::Valid), "got {state:?}");
        assert!(core.live.lock().unwrap().is_some());
    }

    #[tokio::test]
    async fn restore_session_with_auth_failure_reports_expired_without_error() {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async()
            .await;
        let core = core_at("restore-expired");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = Session {
            sid: "SID-STALE".into(),
            syno_token: None,
            username: "photouser".into(),
            device_did: None,
        };
        let state = core.restore_session(conn, session).await.expect("restore does not error on expiry");
        assert!(matches!(state, SessionState::Expired), "got {state:?}");
        assert!(core.live.lock().unwrap().is_none(), "expired restore must not populate Live");
    }

    #[tokio::test]
    async fn sign_out_is_idempotent_without_session() {
        let core = core_at("signout-empty");
        core.sign_out().await.expect("sign_out without a session is a no-op");
        assert!(core.live.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn probe_capabilities_after_login_caches_and_returns() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-PROBE"}}"#)
            .create_async()
            .await;
        let _info = server
            .mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(
                r#"{"success":true,"data":{
                    "SYNO.API.Auth":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"},
                    "SYNO.Foto.Browse.Item":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"},
                    "SYNO.Foto.Thumbnail":{"minVersion":1,"maxVersion":2,"path":"entry.cgi"},
                    "SYNO.FotoTeam.Browse.Item":{"minVersion":1,"maxVersion":7,"path":"entry.cgi"}
                }}"#,
            )
            .create_async()
            .await;
        let core = core_at("probe-caps");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "photouser".into(), "pw".into(), None, None).await.expect("login ok");

        let caps = core.probe_capabilities().await.expect("probe ok");
        assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Browse.Item"));
        assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Thumbnail" && c.max_version == 2));
        assert_eq!(caps.len(), 4);

        // The probe must cache the discovered set into Live.capabilities so
        // later version-pinning calls (Tasks 36/37) can read it without a
        // second round trip.
        let guard = core.live.lock().unwrap();
        let cached = &guard.as_ref().unwrap().capabilities;
        assert_eq!(cached.len(), 4);
        assert!(cached.iter().any(|c| c.name == "SYNO.API.Auth"));
    }

    #[tokio::test]
    async fn probe_capabilities_without_login_returns_auth_error() {
        let core = core_at("probe-caps-no-login");
        let err = core.probe_capabilities().await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
        assert!(core.live.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn crawl_space_persists_and_reports_complete() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let dir = std::env::temp_dir().join(format!("photoscore-crawl-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct Collector(std::sync::Mutex<Vec<CrawlProgress>>);
        impl FfiCrawlObserver for Collector {
            fn on_progress(&self, p: CrawlProgress) { self.0.lock().unwrap().push(p); }
        }
        let obs = Collector(std::sync::Mutex::new(vec![]));
        let final_p = core.crawl_space(Space::Personal, Box::new(obs)).await.expect("crawl ok");
        assert!(final_p.complete);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
        assert!(core.crawl_progress(Space::Personal).unwrap().complete);
    }

    /// Proves the crawl cannot be started without a live session: fails
    /// closed with CoreError rather than panicking or hanging.
    #[tokio::test]
    async fn crawl_space_without_login_returns_auth_error() {
        let core = core_at("crawl-no-login");
        struct Collector;
        impl FfiCrawlObserver for Collector {
            fn on_progress(&self, _p: CrawlProgress) {}
        }
        let err = core.crawl_space(Space::Personal, Box::new(Collector)).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Drives crawl_space to completion end-to-end through a real async
    /// runtime: if `page_source_for` (or anything else in crawl_space) held
    /// the `live`/`store` std Mutex guard across an `.await` point, this
    /// test would deadlock/hang rather than complete, because the crawl's
    /// PageSource call and Store writes both need to run while some other
    /// code path could want the same lock. A passing, terminating test here
    /// is a liveness proof, not just a correctness check.
    #[tokio::test]
    async fn crawl_space_completes_without_deadlock() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let core = core_at("crawl-liveness");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct NoopObserver;
        impl FfiCrawlObserver for NoopObserver {
            fn on_progress(&self, _p: CrawlProgress) {}
        }

        // A generous but finite timeout: if a Mutex guard were held across
        // the crawl's internal .await points, this call would hang forever
        // and the timeout would fire, failing the test instead of the whole
        // suite hanging.
        let result = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            core.crawl_space(Space::Personal, Box::new(NoopObserver)),
        )
        .await
        .expect("crawl_space must not deadlock/hang");
        assert!(result.expect("crawl ok").complete);
    }

    /// Regression test for the Store-bricking bug: forces the crawl itself
    /// to panic (via an observer whose `on_progress` panics, called from
    /// inside `Crawler::crawl_space` on the blocking thread), asserts
    /// `crawl_space` surfaces the panic as an ordinary `CoreError` rather
    /// than hanging or aborting the test process, and then asserts a
    /// subsequent call succeeds - proving `run_with_store` actually put the
    /// `Store` back rather than leaving `self.store` permanently `None`.
    #[tokio::test]
    async fn crawl_space_recovers_store_after_panic() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let core = core_at("crawl-panic-recovery");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct PanickingObserver;
        impl FfiCrawlObserver for PanickingObserver {
            fn on_progress(&self, _p: CrawlProgress) {
                panic!("simulated crawl panic");
            }
        }

        // Suppress the default panic backtrace noise for this expected panic
        // so the test output stays readable; restore it afterward.
        let default_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let panicked = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            core.crawl_space(Space::Personal, Box::new(PanickingObserver)),
        )
        .await
        .expect("crawl_space must not hang when the crawl panics");
        std::panic::set_hook(default_hook);

        let err = panicked.expect_err("a panicking crawl must surface as an Err, not a hang");
        assert!(matches!(err, CoreError::Storage { .. }), "got {err:?}");

        // The real assertion: the Store must have been put back. If it
        // weren't, every call below would fail with the "store busy" error
        // forever instead of succeeding. (The single page was already
        // upserted before the observer callback panicked, so the asset is
        // present; what matters here is that the read succeeds at all.)
        let count = core.asset_count(Space::Personal).expect("store must be usable again after the panic");
        assert_eq!(count, 1);
        let progress = core.crawl_progress(Space::Personal).expect("progress read must succeed after the panic");
        assert!(progress.complete, "the crawl had already persisted the completing page before the panic");

        // And a fresh crawl on the same core must work end to end, proving
        // the recovered Store is not just readable but fully functional.
        struct NoopObserver;
        impl FfiCrawlObserver for NoopObserver {
            fn on_progress(&self, _p: CrawlProgress) {}
        }
        let retried = core.crawl_space(Space::Personal, Box::new(NoopObserver)).await.expect("retry crawl ok");
        assert!(retried.complete);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
    }

    #[tokio::test]
    async fn reconcile_delta_runs_after_crawl() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Browse.Item":{"path":"entry.cgi","minVersion":1,"maxVersion":1}}}"#)
            .create_async().await;
        let _list = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "list".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"list":[{"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1"}}}]}}"#)
            .create_async().await;
        let core = core_at("reconcile");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        struct NoopObserver;
        impl FfiCrawlObserver for NoopObserver {
            fn on_progress(&self, _p: CrawlProgress) {}
        }
        core.crawl_space(Space::Personal, Box::new(NoopObserver)).await.expect("crawl ok");

        let progress = core.reconcile_delta(Space::Personal).await.expect("reconcile ok");
        assert_eq!(progress.done, 1);
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 1);
    }

    #[tokio::test]
    async fn crawl_progress_without_any_crawl_reports_zero_incomplete() {
        let core = core_at("progress-empty");
        let progress = core.crawl_progress(Space::Personal).expect("progress read ok");
        assert!(!progress.complete);
        assert_eq!(progress.done, 0);
    }

    /// Task 36 brief's exact TDD test: on a freshly opened, never-logged-in
    /// core, the three local read methods all succeed (no auth required) and
    /// report empty/zero rather than erroring.
    #[test]
    fn fetch_assets_and_count_are_local_reads() {
        let dir = std::env::temp_dir().join(format!("photoscore-fetch-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();
        assert_eq!(core.asset_count(Space::Personal).unwrap(), 0);
        assert!(core.fetch_assets(Space::Personal, 0, 10).unwrap().is_empty());
        assert!(core.fetch_albums(Space::Personal).unwrap().is_empty());
    }

    /// Proves fetch_assets/fetch_albums actually delegate to the Store's real
    /// windowed queries rather than being stubs: upserts assets/albums across
    /// both spaces directly via the Store, then checks the core-level reads
    /// return the right rows, the right order, the right window, and never
    /// leak across spaces.
    #[test]
    fn fetch_assets_and_albums_return_upserted_rows_windowed_and_space_scoped() {
        let dir = std::env::temp_dir().join(format!("photoscore-fetch-data-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::create_dir_all(dir.join("cache")).unwrap();
        let core = PhotosCore::new(dir.join("db").to_string_lossy().into(), dir.join("cache").to_string_lossy().into()).unwrap();

        {
            let guard = core.store.lock().unwrap();
            let store = guard.as_ref().unwrap();
            for id in 1..=5 {
                store
                    .upsert_asset(&Asset {
                        id,
                        cache_key: format!("ck{id}"),
                        filename: format!("IMG_{id}.jpg"),
                        media_kind: models::MediaKind::Photo,
                        taken_at: Some(id * 10),
                        added_at: Some(1000),
                        width: Some(4000),
                        height: Some(3000),
                        file_size: Some(2_000_000),
                        space: Space::Personal,
                        server_version: Some(1),
                    })
                    .unwrap();
            }
            store
                .upsert_asset(&Asset {
                    id: 99,
                    cache_key: "ck99".into(),
                    filename: "shared.jpg".into(),
                    media_kind: models::MediaKind::Photo,
                    taken_at: Some(500),
                    added_at: Some(1000),
                    width: None,
                    height: None,
                    file_size: None,
                    space: Space::Shared,
                    server_version: Some(1),
                })
                .unwrap();
            store
                .upsert_album(&models::Album {
                    id: 1,
                    name: "Trip".into(),
                    item_count: 3,
                    cover_cache_key: Some("cover1".into()),
                    space: Space::Personal,
                })
                .unwrap();
            store
                .upsert_album(&models::Album {
                    id: 2,
                    name: "SharedAlbum".into(),
                    item_count: 1,
                    cover_cache_key: None,
                    space: Space::Shared,
                })
                .unwrap();
        }

        assert_eq!(core.asset_count(Space::Personal).unwrap(), 5);
        assert_eq!(core.asset_count(Space::Shared).unwrap(), 1);

        // Newest-first (by taken_at), windowed by offset/limit.
        let first_page = core.fetch_assets(Space::Personal, 0, 2).unwrap();
        assert_eq!(first_page.iter().map(|a| a.id).collect::<Vec<_>>(), vec![5, 4]);
        let second_page = core.fetch_assets(Space::Personal, 2, 2).unwrap();
        assert_eq!(second_page.iter().map(|a| a.id).collect::<Vec<_>>(), vec![3, 2]);

        // Space isolation: Personal reads never see the Shared asset.
        assert!(core.fetch_assets(Space::Personal, 0, 100).unwrap().iter().all(|a| a.id != 99));
        let shared_assets = core.fetch_assets(Space::Shared, 0, 100).unwrap();
        assert_eq!(shared_assets.len(), 1);
        assert_eq!(shared_assets[0].id, 99);

        let personal_albums = core.fetch_albums(Space::Personal).unwrap();
        assert_eq!(personal_albums.len(), 1);
        assert_eq!(personal_albums[0].name, "Trip");
        let shared_albums = core.fetch_albums(Space::Shared).unwrap();
        assert_eq!(shared_albums.len(), 1);
        assert_eq!(shared_albums[0].name, "SharedAlbum");
    }

    /// Fail-closed proof: if the Store has been taken out of the mutex (the
    /// same window a crawl/reconcile briefly holds via `run_with_store`),
    /// every local read method must return `CoreError::Storage` rather than
    /// panicking on an `Option::unwrap`.
    #[test]
    fn local_reads_fail_closed_when_store_is_busy() {
        let core = core_at("fetch-busy");
        let taken = core.store.lock().unwrap().take();
        assert!(taken.is_some(), "test setup: store must have been Some before taking it");

        let count_err = core.asset_count(Space::Personal).unwrap_err();
        assert!(matches!(count_err, CoreError::Storage { .. }), "got {count_err:?}");

        let fetch_err = core.fetch_assets(Space::Personal, 0, 10).unwrap_err();
        assert!(matches!(fetch_err, CoreError::Storage { .. }), "got {fetch_err:?}");

        let albums_err = core.fetch_albums(Space::Personal).unwrap_err();
        assert!(matches!(albums_err, CoreError::Storage { .. }), "got {albums_err:?}");

        // Put the store back so nothing else in the process is left bricked.
        *core.store.lock().unwrap() = taken;
    }

    #[tokio::test]
    async fn sign_out_clears_live_after_login() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-OUT"}}"#)
            .create_async()
            .await;
        let _logout = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "logout".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{}}"#)
            .create_async()
            .await;
        let core = core_at("signout-live");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "photouser".into(), "pw".into(), None, None).await.expect("login ok");
        assert!(core.live.lock().unwrap().is_some());

        core.sign_out().await.expect("sign_out ok");
        assert!(core.live.lock().unwrap().is_none(), "sign_out must clear Live");
    }

    /// Task 37 TDD: a thumbnail cache miss fetches the bytes over the network,
    /// writes them to the composite-key cache path, and returns both the path
    /// and the bytes.
    #[tokio::test]
    async fn thumbnail_cache_miss_fetches_and_writes_cache_file() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _thumb = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "101".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK1".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0xFF, 0xD8, 0xFF])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-miss");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let data = core.thumbnail(Space::Personal, 101, "CK1".into(), models::ThumbnailSize::Sm).await.expect("thumb ok");
        assert!(data.cached_path.contains("thumbs"));
        assert!(data.cached_path.ends_with(".jpg"));
        assert!(std::path::Path::new(&data.cached_path).exists());
        assert_eq!(data.bytes, vec![0xFF, 0xD8, 0xFF]);
        _thumb.assert_async().await;
    }

    /// Task 37 TDD: a second call with the SAME composite key (space, asset,
    /// size, cache_key) must be served entirely from disk, without a second
    /// network round trip. Proven by asserting the thumbnail mock received
    /// exactly one call total across both `thumbnail()` invocations.
    #[tokio::test]
    async fn thumbnail_cache_hit_skips_network() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _thumb = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "202".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK2".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0xAA, 0xBB])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-hit");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let first = core.thumbnail(Space::Personal, 202, "CK2".into(), models::ThumbnailSize::M).await.expect("first ok");
        let second = core.thumbnail(Space::Personal, 202, "CK2".into(), models::ThumbnailSize::M).await.expect("second ok");
        assert_eq!(first.cached_path, second.cached_path);
        assert_eq!(second.bytes, vec![0xAA, 0xBB]);
        // The mock is `.expect(1)`: if the cache hit had reached the network
        // again, `.assert_async()` below would fail.
        _thumb.assert_async().await;
    }

    /// Task 37 TDD: a DIFFERENT cache_key for the same asset/size must miss
    /// the cache and re-fetch, proving the composite key includes cache_key
    /// rather than just (space, asset_id, size).
    #[tokio::test]
    async fn thumbnail_different_cache_key_invalidates_and_refetches() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _thumb_ck1 = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "303".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK-OLD".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0x01])
            .expect(1)
            .create_async().await;
        let _thumb_ck2 = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "303".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), "CK-NEW".into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0x02])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-invalidate");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let old = core.thumbnail(Space::Personal, 303, "CK-OLD".into(), models::ThumbnailSize::Xl).await.expect("old ok");
        let new = core.thumbnail(Space::Personal, 303, "CK-NEW".into(), models::ThumbnailSize::Xl).await.expect("new ok");
        assert_ne!(old.cached_path, new.cached_path, "a changed cache_key must produce a distinct cache path");
        assert_eq!(old.bytes, vec![0x01]);
        assert_eq!(new.bytes, vec![0x02]);
        _thumb_ck1.assert_async().await;
        _thumb_ck2.assert_async().await;
    }

    /// Security fix: a `cache_key` containing path-traversal/path-separator
    /// bytes (as could arrive from a malformed or malicious NAS response)
    /// must not escape the cache directory. The filename is a hash of the
    /// composite key, so the raw `cache_key` never appears literally in the
    /// path; the resulting file's parent directory must still be exactly
    /// `{cache_dir}/thumbs`, and the fetch must still succeed (a hit/miss on
    /// the hashed path, not a filesystem error or an escape).
    #[tokio::test]
    async fn thumbnail_cache_key_with_path_traversal_stays_inside_cache_dir() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Thumbnail":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let malicious_key = "../../../../../../tmp/evil";
        let _thumb = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
                mockito::Matcher::UrlEncoded("id".into(), "404".into()),
                mockito::Matcher::UrlEncoded("cache_key".into(), malicious_key.into()),
            ]))
            .with_status(200).with_header("content-type", "image/jpeg")
            .with_body(vec![0x99])
            .expect(1)
            .create_async().await;
        let core = core_at("thumb-traversal");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let data = core
            .thumbnail(Space::Personal, 404, malicious_key.into(), models::ThumbnailSize::Sm)
            .await
            .expect("thumb ok even with a hostile cache_key");
        assert_eq!(data.bytes, vec![0x99]);

        let written = std::path::Path::new(&data.cached_path);
        assert!(written.exists(), "cache file must exist at the returned path");
        let expected_dir = std::path::Path::new(&core.cache_dir).join("thumbs");
        assert_eq!(
            written.parent().unwrap().canonicalize().unwrap(),
            expected_dir.canonicalize().unwrap(),
            "cache_key must never be able to steer the file outside {{cache_dir}}/thumbs"
        );
        // The raw cache_key must never appear literally in the path: proof
        // that the filename is derived from a hash, not string interpolation.
        assert!(!data.cached_path.contains(".."), "path must not contain traversal segments");
        assert!(
            !data.cached_path.contains("evil"),
            "the raw cache_key content must not appear literally in the cache path"
        );
        _thumb.assert_async().await;
    }

    /// Task 37 TDD: fail-closed when no session is held; no network hit.
    #[tokio::test]
    async fn thumbnail_without_login_returns_auth_error() {
        let core = core_at("thumb-no-login");
        let err = core.thumbnail(Space::Personal, 1, "CK".into(), models::ThumbnailSize::Sm).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Task 37 TDD: download_original fetches full-resolution bytes and
    /// writes them to a path it returns; read-only, no NAS write.
    #[tokio::test]
    async fn download_original_returns_path_to_downloaded_bytes() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _dl = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
                mockito::Matcher::UrlEncoded("method".into(), "download".into()),
            ]))
            .with_status(200).with_header("content-type", "application/octet-stream")
            .with_body(b"ORIGINAL-BYTES".to_vec())
            .create_async().await;
        let core = core_at("download-ok");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let path = core.download_original(Space::Personal, 101, "CK1".into()).await.expect("download ok");
        assert!(std::path::Path::new(&path).exists());
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(bytes, b"ORIGINAL-BYTES".to_vec());
    }

    /// Task 37 TDD: a JSON error envelope from the download endpoint maps to
    /// a CoreError via `map_binary_or_error`, not a panic or silent success.
    #[tokio::test]
    async fn download_original_json_error_maps_to_core_error() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("method=login".into()))
            .with_status(200).with_body(r#"{"success":true,"data":{"sid":"S"}}"#).create_async().await;
        let _info = server.mock("GET", "/webapi/query.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"SYNO.Foto.Download":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#)
            .create_async().await;
        let _dl = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
                mockito::Matcher::UrlEncoded("method".into(), "download".into()),
            ]))
            .with_status(200).with_header("content-type", "application/json")
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async().await;
        let core = core_at("download-err");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        core.login(conn, "u".into(), "p".into(), None, None).await.unwrap();
        core.probe_capabilities().await.unwrap();

        let err = core.download_original(Space::Personal, 101, "CK1".into()).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// Task 37 TDD: fail-closed when no session is held; no network hit.
    #[tokio::test]
    async fn download_original_without_login_returns_auth_error() {
        let core = core_at("download-no-login");
        let err = core.download_original(Space::Personal, 1, "CK".into()).await.unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    /// The FFI surface the Swift UI will call for trust-on-first-use: given a
    /// bare host, `fetch_certificate` returns a `CertInfo` with the DER, a
    /// 64-hex-char SHA-256 fingerprint, and a subject string, with no session
    /// required at all (this can be called before any login).
    #[tokio::test]
    async fn fetch_certificate_returns_cert_info_for_a_real_tls_server() {
        let rcgen::CertifiedKey { cert, signing_key } =
            rcgen::generate_simple_self_signed(vec!["127.0.0.1".to_string()]).expect("self-signed cert generates");
        let cert_der = cert.der().to_vec();
        let key_der = signing_key.serialize_der();
        let server_config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(
                vec![rustls_pki_types::CertificateDer::from(cert_der.clone())],
                rustls_pki_types::PrivateKeyDer::try_from(key_der).expect("key parses"),
            )
            .expect("server config builds");
        let acceptor = tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(server_config));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.expect("listener binds");
        let addr = listener.local_addr().expect("listener has an addr");
        tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else { return };
                let acceptor = acceptor.clone();
                tokio::spawn(async move {
                    let _ = acceptor.accept(stream).await;
                });
            }
        });

        let core = core_at("fetch-cert");
        let info = core
            .fetch_certificate(format!("{}:{}", addr.ip(), addr.port()))
            .await
            .expect("fetch_certificate should succeed against a real TLS server");
        assert_eq!(info.der, cert_der);
        assert_eq!(info.sha256_hex.len(), 64);
        assert!(!info.subject.is_empty());
    }

    /// End-to-end (through `PhotosCore::login`, not just `synology_api::auth`
    /// directly): a login with otp captures the device token onto the
    /// returned `Session`, and passing that token back into a later `login`
    /// call succeeds without supplying otp again.
    #[tokio::test]
    async fn login_round_trips_device_token_through_the_core_facade() {
        let mut server = mockito::Server::new_async().await;
        let _first = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("otp_code=999999".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-1","did":"CORE-DEVICE-TOKEN"}}"#)
            .create_async()
            .await;
        let core = core_at("device-token-roundtrip");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
        let session = core
            .login(conn.clone(), "photouser".into(), "pw".into(), Some("999999".into()), None)
            .await
            .expect("first login with otp ok");
        assert_eq!(session.device_did.as_deref(), Some("CORE-DEVICE-TOKEN"));

        // Trap: the second login must not need to send otp_code again.
        let _trap = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("otp_code".into()))
            .expect(0)
            .create_async()
            .await;
        let _second = server
            .mock("POST", "/webapi/entry.cgi")
            .match_body(mockito::Matcher::Regex("did=CORE-DEVICE-TOKEN".into()))
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-2"}}"#)
            .create_async()
            .await;
        let session2 = core
            .login(conn, "photouser".into(), "pw".into(), None, session.device_did.clone())
            .await
            .expect("second login with stored device token should succeed without otp");
        assert_eq!(session2.sid, "SID-2");
        _trap.assert_async().await;
    }
}
