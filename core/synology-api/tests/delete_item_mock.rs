use mockito::Matcher;
use models::{CoreError, Space};
use synology_api::delete_item::permanent_delete;
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

#[tokio::test]
async fn permanent_delete_bare_success_is_ok() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO.Foto.Browse.Item".into()),
            Matcher::Regex("method=delete".into()),
            // id=[73412] url-encodes to id=%5B73412%5D
            Matcher::Regex("id=%5B73412%5D".into()),
            Matcher::Regex("version=7".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        // The verified real-NAS shape: bare success, NO data field.
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    permanent_delete(&t, "SID", Space::Personal, &[73412], 7, Some("TOK"))
        .await
        .expect("permanent_delete ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn permanent_delete_sends_syno_token_header() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK123")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    permanent_delete(&t, "SID", Space::Personal, &[1, 2, 3], 7, Some("TOK123"))
        .await
        .expect("permanent_delete ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn permanent_delete_maps_failure_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = permanent_delete(&t, "SID", Space::Personal, &[1], 7, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn permanent_delete_shared_uses_fototeam_namespace() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("api=SYNO.FotoTeam.Browse.Item".into()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    permanent_delete(&t, "SID", Space::Shared, &[1], 7, Some("TOK"))
        .await
        .expect("permanent_delete ok");
    _m.assert_async().await;
}
