use mockito::Matcher;
use models::{Connection, MediaKind, Space};
use synology_api::browse::search;
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
        .expect("transport builds")
}

/// Pins the real request shape confirmed against the NAS: api
/// SYNO.Foto.Search.Search, method list_item, param keyword (not query),
/// with the X-SYNO-TOKEN header.
#[tokio::test]
async fn search_sends_list_item_method_and_keyword_param_with_token_header() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Search".into()),
            Matcher::UrlEncoded("method".into(), "list_item".into()),
            Matcher::UrlEncoded("keyword".into(), "food".into()),
        ]))
        .match_header("X-SYNO-TOKEN", "TOK")
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":73507,"filename":"IMG_1619.JPG","type":"live","filesize":1671651,"time":1480105574,
             "additional":{"thumbnail":{"cache_key":"55853_1480101974","unit_id":55853},"resolution":{"width":3024,"height":4032}}}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = search(&t, "SID", "food", 0, 10, 1, Some("TOK")).await.expect("search ok");
    assert_eq!(assets.len(), 1);
    let a = &assets[0];
    assert_eq!(a.id, 73507);
    assert_eq!(a.unit_id, 55853);
    assert_eq!(a.cache_key, "55853_1480101974");
    assert_eq!(a.filename, "IMG_1619.JPG");
    // "live" is a type never seen from Browse.Item; it must decode as
    // Unknown rather than failing the whole search, per the fail-open
    // convention every other unrecognized type already follows.
    assert_eq!(a.media_kind, MediaKind::Unknown);
    assert_eq!(a.width, Some(3024));
    assert_eq!(a.height, Some(4032));
    assert_eq!(a.space, Space::Personal);
    m.assert_async().await;
}

#[tokio::test]
async fn search_omits_token_header_when_none() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = search(&t, "SID", "food", 0, 10, 1, None).await.expect("search ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

/// A clean no-results search (a keyword that matches nothing) must decode
/// to an empty vec, not an error -- this is the normal "no results" path
/// the empty-state UI depends on, not a failure case.
#[tokio::test]
async fn search_decodes_empty_result_cleanly() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("keyword".into(), "zzzznosuchthing123".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = search(&t, "SID", "zzzznosuchthing123", 0, 10, 1, None).await.expect("search ok");
    assert!(assets.is_empty(), "a keyword with no matches must decode to an empty list, not error");
}

/// One malformed row (missing id) must be skipped without failing the
/// whole page, same discipline as list_items.
#[tokio::test]
async fn search_skips_malformed_rows_without_failing_the_page() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":1,"filename":"a.jpg","type":"photo","additional":{"thumbnail":{"cache_key":"CK1","unit_id":11}}},
            {"filename":"broken.jpg"}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = search(&t, "SID", "food", 0, 10, 1, None).await.expect("search ok");
    assert_eq!(assets.len(), 1, "the malformed row (missing id) must be skipped, not fail the whole page");
}

/// A row missing cache_key is unusable for thumbnails/downloads and is
/// skipped, same discipline as list_items.
#[tokio::test]
async fn search_skips_rows_missing_cache_key() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":1,"filename":"nocachekey.jpg","type":"photo"}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = search(&t, "SID", "food", 0, 10, 1, None).await.expect("search ok");
    assert!(assets.is_empty(), "a row with no cache_key is not usable and must be skipped");
}

#[tokio::test]
async fn search_maps_envelope_error() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":100}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = search(&t, "SID", "food", 0, 10, 1, None).await.unwrap_err();
    assert!(matches!(err, models::CoreError::UnexpectedResponse { .. }), "got {err:?}");
}

/// search() is reachable through the crate's public facade, same smoke
/// pattern as discovery_mock's reexports check.
#[tokio::test]
async fn search_reachable_through_facade() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Search".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    assert!(synology_api::search(&t, "SID", "food", 0, 10, 1, None).await.unwrap().is_empty());
}
