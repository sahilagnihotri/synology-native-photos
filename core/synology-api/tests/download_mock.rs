use mockito::Matcher;
use models::{Connection, Space};
use synology_api::download::download_original;
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection {
        host: server.url(),
        verify_tls: true,
        pinned_cert_der: None,
        allow_untrusted_tls: false,
    })
    .expect("transport builds")
}

// NOTE: mocked path is `/webapi/entry.cgi`, matching the verified fact in
// documentation/phase0-probe-results.md and transport.rs's `entry_url()` -
// NOT the `/photo/webapi/entry.cgi` path from the original task brief
// snippet, which predates that verification.

#[tokio::test]
async fn download_returns_original_bytes() {
    let mut server = mockito::Server::new_async().await;
    let payload = b"ORIGINAL-FILE-BYTES".to_vec();
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Download".into()),
            Matcher::UrlEncoded("method".into(), "download".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/octet-stream")
        .with_body(payload.clone())
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, None)
        .await
        .expect("download ok");
    assert_eq!(bytes, payload);
}

#[tokio::test]
async fn download_shared_uses_fototeam_namespace() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded(
            "api".into(),
            "SYNO.FotoTeam.Download".into(),
        ))
        .with_status(200)
        .with_header("content-type", "application/octet-stream")
        .with_body(b"X")
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = download_original(&t, "SID", Space::Shared, 7, "CK7", 2, None)
        .await
        .expect("download ok");
    assert_eq!(bytes, b"X".to_vec());
}

#[tokio::test]
async fn download_json_error_maps_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":401}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, None)
        .await
        .unwrap_err();
    assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn download_sends_unit_id_and_cache_key_params() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("unit_id".into(), "[101]".into()),
            Matcher::UrlEncoded("cache_key".into(), "CK101".into()),
            Matcher::UrlEncoded("_sid".into(), "SID".into()),
            Matcher::UrlEncoded("version".into(), "2".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/octet-stream")
        .with_body(b"BYTES")
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, None)
        .await
        .expect("download ok");
    assert_eq!(bytes, b"BYTES".to_vec());
}

#[tokio::test]
async fn download_sends_syno_token_header_when_present() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK123")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/octet-stream")
        .with_body(b"BYTES")
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, Some("TOK123"))
        .await
        .expect("download ok with token header");
    assert_eq!(bytes, b"BYTES".to_vec());
    _m.assert_async().await;
}

#[tokio::test]
async fn download_omits_syno_token_header_when_absent() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", Matcher::Missing)
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/octet-stream")
        .with_body(b"BYTES")
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, None)
        .await
        .expect("download ok without token header");
    assert_eq!(bytes, b"BYTES".to_vec());
    _m.assert_async().await;
}

/// R1-7: a proxy or a restarting DSM answering 503 with a text/plain body
/// must never come back as the original's bytes. The editor would otherwise
/// duplicate and upload "Service Unavailable" as the edited copy.
#[tokio::test]
async fn download_non_2xx_text_body_is_an_error_not_file_bytes() {
    for (status, body) in [
        (503, "Service Unavailable"),
        (502, "Bad Gateway"),
        (404, "nope"),
    ] {
        let mut server = mockito::Server::new_async().await;
        let _m = server
            .mock("GET", "/webapi/entry.cgi")
            .match_query(Matcher::Any)
            .with_status(status)
            .with_header("content-type", "text/plain")
            .with_body(body)
            .create_async()
            .await;
        let t = transport_for(&server);
        let result = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, None).await;
        assert!(
            result.is_err(),
            "HTTP {status} must be an error, got Ok({:?})",
            result.map(|b| String::from_utf8_lossy(&b).into_owned())
        );
    }
}

/// A non-2xx reply that still carries a DSM JSON error envelope keeps its
/// specific mapping (here 400, bad credentials, which maps to Auth).
#[tokio::test]
async fn download_non_2xx_json_envelope_keeps_its_error_mapping() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(500)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = download_original(&t, "SID", Space::Personal, 101, "CK101", 2, None)
        .await
        .unwrap_err();
    assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
}
