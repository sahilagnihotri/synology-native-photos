//! Manual integration test against a real Synology NAS. Not run by default.
//! Run with:
//!   SYNO_HOST=https://192.168.1.10:5001 SYNO_USER=photouser SYNO_PASS=... \
//!   SYNO_OTP=123456 cargo test -p synology-api --test real_nas_ignored -- --ignored --nocapture
//! READ-ONLY: logs in, probes capabilities, lists the first page of the personal
//! space, then logs out. Never writes to or deletes from the NAS.

use models::{Connection, Space};
use synology_api::transport::Transport;
use synology_api::{list_items, login, logout, probe_capabilities};

fn env(key: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| panic!("env var {key} must be set for the real NAS test"))
}

#[tokio::test]
#[ignore = "hits a real NAS; requires SYNO_* env vars"]
async fn real_nas_login_probe_list_logout() {
    let host = env("SYNO_HOST");
    let user = env("SYNO_USER");
    let pass = env("SYNO_PASS");
    let otp = std::env::var("SYNO_OTP").ok();
    let connection = Connection { host, verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
    let transport = Transport::new(&connection).expect("transport builds against real NAS");
    let session = login(&transport, &user, &pass, otp.as_deref(), None).await
        .expect("real login should succeed with valid creds + OTP");
    assert!(!session.sid.is_empty(), "sid must be non-empty");
    println!("logged in as {}, syno_token present: {}", session.username, session.syno_token.is_some());
    let caps = probe_capabilities(&transport).await.expect("capability probe should succeed");
    assert!(caps.iter().any(|c| c.name == "SYNO.Foto.Browse.Item"), "NAS must advertise SYNO.Foto.Browse.Item");
    println!("discovered {} capabilities", caps.len());
    let version = synology_api::pin_version(&caps, "SYNO.Foto.Browse.Item", 1)
        .expect("Browse.Item must be available");
    let assets = list_items(&transport, &session.sid, Space::Personal, 0, 25, version).await
        .expect("listing first page should succeed");
    println!("first page returned {} assets", assets.len());
    if let Some(first) = assets.first() {
        assert!(!first.cache_key.is_empty(), "asset cache_key must be populated");
    }
    logout(&transport, &session.sid).await.expect("logout should succeed");
}
