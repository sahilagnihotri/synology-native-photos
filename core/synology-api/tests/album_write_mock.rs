use mockito::Matcher;
use models::{CoreError, Space};
use synology_api::album_write::delete_album;
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

// Every write posts a form body to the shared entry.cgi dispatcher (matching
// the verified delete-probe request shape), so the mocks match on POST body
// regex, not query string.

// --- delete_album -------------------------------------------------------

#[tokio::test]
async fn delete_album_uses_generic_album_api_and_id_array() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            // The generic .Album api, NOT .NormalAlbum, for deleting a whole album.
            Matcher::Regex("api=SYNO.Foto.Browse.Album&".into()),
            Matcher::Regex("method=delete".into()),
            // id=[4242] url-encodes to id=%5B4242%5D
            Matcher::Regex("id=%5B4242%5D".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    delete_album(&t, "SID", Space::Personal, 4242, 1, Some("TOK"))
        .await
        .expect("delete_album ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn delete_album_maps_failure_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = delete_album(&t, "SID", Space::Personal, 1, 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}
