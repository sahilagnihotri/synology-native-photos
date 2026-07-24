use mockito::Matcher;
use models::{Connection, Space, ThumbnailSize};
use synology_api::thumbnail::{fetch_thumbnail, size_param};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
        .expect("transport builds")
}

#[test]
fn size_param_maps_sizes() {
    assert_eq!(size_param(ThumbnailSize::Sm), "sm");
    assert_eq!(size_param(ThumbnailSize::M), "m");
    assert_eq!(size_param(ThumbnailSize::Xl), "xl");
}

#[tokio::test]
async fn fetch_thumbnail_returns_binary_bytes() {
    let mut server = mockito::Server::new_async().await;
    let jpeg_magic = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Thumbnail".into()),
            Matcher::UrlEncoded("method".into(), "get".into()),
            Matcher::UrlEncoded("size".into(), "sm".into()),
            Matcher::UrlEncoded("id".into(), "101".into()),
            Matcher::UrlEncoded("cache_key".into(), "CK101".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "image/jpeg")
        .with_body(jpeg_magic.clone())
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = fetch_thumbnail(&t, "SID", Space::Personal, 101, "CK101", ThumbnailSize::Sm, 2, None)
        .await
        .expect("thumb ok");
    assert_eq!(bytes, jpeg_magic);
}

#[tokio::test]
async fn fetch_thumbnail_json_error_maps_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = fetch_thumbnail(&t, "SID", Space::Personal, 101, "CK101", ThumbnailSize::Sm, 2, None)
        .await
        .unwrap_err();
    assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn fetch_thumbnail_shared_uses_fototeam_namespace() {
    let mut server = mockito::Server::new_async().await;
    let jpeg_magic = vec![0xFF, 0xD8, 0xFF, 0xE0];
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.FotoTeam.Thumbnail".into()))
        .with_status(200)
        .with_header("content-type", "image/jpeg")
        .with_body(jpeg_magic.clone())
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = fetch_thumbnail(&t, "SID", Space::Shared, 202, "CK202", ThumbnailSize::M, 2, None)
        .await
        .expect("thumb ok");
    assert_eq!(bytes, jpeg_magic);
}

#[tokio::test]
async fn fetch_thumbnail_sends_syno_token_header_when_present() {
    let mut server = mockito::Server::new_async().await;
    let jpeg_magic = vec![0xFF, 0xD8, 0xFF, 0xE0];
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK123")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "image/jpeg")
        .with_body(jpeg_magic.clone())
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = fetch_thumbnail(&t, "SID", Space::Personal, 101, "CK101", ThumbnailSize::Sm, 2, Some("TOK123"))
        .await
        .expect("thumb ok with token header");
    assert_eq!(bytes, jpeg_magic);
    _m.assert_async().await;
}

#[tokio::test]
async fn fetch_thumbnail_omits_syno_token_header_when_absent() {
    let mut server = mockito::Server::new_async().await;
    let jpeg_magic = vec![0xFF, 0xD8, 0xFF, 0xE0];
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", Matcher::Missing)
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "image/jpeg")
        .with_body(jpeg_magic.clone())
        .create_async()
        .await;
    let t = transport_for(&server);
    let bytes = fetch_thumbnail(&t, "SID", Space::Personal, 101, "CK101", ThumbnailSize::Sm, 2, None)
        .await
        .expect("thumb ok without token header");
    assert_eq!(bytes, jpeg_magic);
    _m.assert_async().await;
}
