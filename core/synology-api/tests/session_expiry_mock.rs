//! R1-4: DSM answers 106 (session timeout), 107 (session interrupted by a
//! duplicate login) and 119 (SID not found) when the session is gone. They
//! must map to `Auth`, the variant callers already treat as "sign in again",
//! not to a generic `UnexpectedResponse`. All traffic goes to a localhost
//! mock server.

use mockito::Matcher;
use models::{CoreError, RecycleBinStatus};
use synology_api::recycle::{recycle_bin_status, restore_recycle_item_with_polling, TaskPolling};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&models::Connection {
        host: server.url(),
        verify_tls: true,
        pinned_cert_der: None,
        allow_untrusted_tls: false,
    })
    .expect("transport builds")
}

#[test]
fn session_codes_map_to_auth() {
    for code in [106, 107, 119] {
        let err = synology_api::map_error_code(code);
        assert!(
            matches!(err, CoreError::Auth { .. }),
            "code {code} should be Auth, got {err:?}"
        );
    }
}

#[tokio::test]
async fn recycle_bin_status_surfaces_an_expired_session() {
    for code in [106, 107, 119] {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(Matcher::Any)
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(format!(r#"{{"success":false,"error":{{"code":{code}}}}}"#))
            .create_async()
            .await;
        let t = transport_for(&server);
        let result = recycle_bin_status(&t, "SID", Some("TOK")).await;
        assert!(
            matches!(result, Err(CoreError::Auth { .. })),
            "code {code}: an expired session is not an unknown bin state, got {result:?}"
        );
        assert_ne!(result.ok(), Some(RecycleBinStatus::Unknown));
    }
}

/// The restore precheck lists the destination folder. When that listing
/// says the session is gone, the restore stops with `Auth` and queues no
/// move.
#[tokio::test]
async fn restore_with_an_expired_session_is_auth_and_moves_nothing() {
    let mut server = mockito::Server::new_async().await;
    let _list = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":119}}"#)
        .create_async()
        .await;
    let mv = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true}"#)
        .expect(0)
        .create_async()
        .await;
    let t = transport_for(&server);
    let result = restore_recycle_item_with_polling(
        &t,
        "SID",
        Some("TOK"),
        "/home/#recycle/Photos/a.jpg",
        TaskPolling {
            attempts: 2,
            interval: std::time::Duration::from_millis(1),
        },
    )
    .await;
    assert!(
        matches!(result, Err(CoreError::Auth { .. })),
        "got {result:?}"
    );
    mv.assert_async().await;
}
