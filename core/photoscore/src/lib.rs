//! The UniFFI boundary crate exposing PhotosCore to Swift.

use std::sync::{Arc, Mutex};

use models::{ApiCapability, Connection, CoreError, CrawlProgress, Session, SessionState};
use persistence::Store;
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
#[derive(uniffi::Object)]
pub struct PhotosCore {
    store: Mutex<Store>,
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
        Ok(Arc::new(PhotosCore { store: Mutex::new(store), cache_dir, live: Mutex::new(None) }))
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
