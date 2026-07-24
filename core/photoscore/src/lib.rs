//! The UniFFI boundary crate exposing PhotosCore to Swift.

use std::sync::{Arc, Mutex};

use models::{ApiCapability, Connection, CoreError, CrawlProgress, Session, SessionState, Space};
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
}

#[async_trait::async_trait]
impl PageSource for ApiPageSource {
    async fn list_items(&self, space: Space, offset: u32, limit: u32) -> Result<AssetPage, CoreError> {
        let assets = synology_api::list_items(&self.transport, &self.sid, space, offset, limit, self.version).await?;
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
/// returns. The mutex guard itself is only ever held for the instant of the
/// swap, never across any `.await`.
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
    /// `otp_code` is forwarded to `synology_api::login` untouched: `None`
    /// omits the param entirely, so an account with 2FA enabled answers
    /// with `CoreError::OtpRequired` (see `synology_api::auth`), which the
    /// Swift UI is expected to catch, prompt for a code, and retry with
    /// `otp_code = Some(code)`.
    ///
    /// On success, replaces any previously held `Live` state with a fresh
    /// transport/session pair (capability probe deferred to first use, so
    /// login itself stays a single round trip).
    pub async fn login(
        &self,
        connection: Connection,
        username: String,
        password: String,
        otp_code: Option<String>,
    ) -> Result<Session, CoreError> {
        let transport = Transport::new(&connection)?;
        let session = synology_api::login(&transport, &username, &password, otp_code.as_deref()).await?;
        let mut guard = self.live.lock().expect("live mutex poisoned");
        *guard = Some(Live {
            transport,
            session: session.clone(),
            connection,
            capabilities: Vec::new(),
        });
        Ok(session)
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
    /// thread so `&Store` never needs to be `Send`. Once the blocking task
    /// returns (success or error), the `Store` is always moved back into
    /// `self.store` before the result is propagated, so a later call still
    /// has a store to work with. The mutex is locked again only for that
    /// final swap-back, again never across an `.await`.
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
            let result = handle.block_on(work(&store));
            (store, result)
        })
        .await;

        match join {
            Ok((store, result)) => {
                let mut guard = self.store.lock().expect("store mutex poisoned");
                *guard = Some(store);
                result
            }
            Err(e) => {
                // The blocking task panicked before it could hand the
                // `Store` back; `store` stays `None` (fail-closed - see
                // `store_busy_err`) rather than silently leaving the core
                // permanently unusable behind a misleading error.
                Err(CoreError::Storage { message: format!("crawl/reconcile task panicked: {e}") })
            }
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
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":true,"data":{"sid":"SID-CORE","synotoken":"TK"}}"#)
            .create_async()
            .await;
        let core = core_at("login");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        let session = core
            .login(conn, "photouser".into(), "pw".into(), Some("123456".into()))
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
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::Any)
            .with_status(200)
            .with_body(r#"{"success":false,"error":{"code":403}}"#)
            .create_async()
            .await;
        let core = core_at("login-otp");
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        let err = core
            .login(conn, "photouser".into(), "pw".into(), None)
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
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
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "login".into()))
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        core.login(conn, "photouser".into(), "pw".into(), None).await.expect("login ok");

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
        let _login = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "login".into()))
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        core.login(conn, "u".into(), "p".into(), None).await.unwrap();
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
        let _login = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "login".into()))
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        core.login(conn, "u".into(), "p".into(), None).await.unwrap();
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

    #[tokio::test]
    async fn reconcile_delta_runs_after_crawl() {
        let mut server = mockito::Server::new_async().await;
        let _login = server.mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "login".into()))
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        core.login(conn, "u".into(), "p".into(), None).await.unwrap();
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

    #[tokio::test]
    async fn sign_out_clears_live_after_login() {
        let mut server = mockito::Server::new_async().await;
        let _login = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::UrlEncoded("method".into(), "login".into()))
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
        let conn = Connection { host: server.url(), verify_tls: true, pinned_cert_der: None };
        core.login(conn, "photouser".into(), "pw".into(), None).await.expect("login ok");
        assert!(core.live.lock().unwrap().is_some());

        core.sign_out().await.expect("sign_out ok");
        assert!(core.live.lock().unwrap().is_none(), "sign_out must clear Live");
    }
}
