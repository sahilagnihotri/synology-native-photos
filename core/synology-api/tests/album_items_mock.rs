use mockito::Matcher;
use models::{Connection, MediaKind, Space};
use synology_api::browse::list_album_items;
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

// Item shape taken from a real DS925+ `Browse.Item list` response (v4, Personal
// space). The probed account has no albums, and `album_id` only narrows the
// same API, so an album page carries the same element shape.
const REAL_SHAPE_PAGE: &str = r#"{"success":true,"data":{"list":[
 {"id":73609,"filename":"IMG_7521.HEIC","filesize":1960491,"time":1784754229,
  "indexed_time":1788724426229,"owner_user_id":1,"folder_id":385,"type":"photo",
  "additional":{"resolution":{"width":3024,"height":3024},
   "thumbnail":{"m":"ready","xl":"ready","preview":"broken","sm":"ready",
                "cache_key":"55932_1788825603","unit_id":55932},
   "orientation":1,"orientation_original":1}}
]}}"#;

#[tokio::test]
async fn list_album_items_sends_album_id_paging_and_token() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
            Matcher::UrlEncoded("method".into(), "list".into()),
            Matcher::UrlEncoded("album_id".into(), "4242".into()),
            Matcher::UrlEncoded("offset".into(), "50".into()),
            Matcher::UrlEncoded("limit".into(), "25".into()),
            Matcher::Regex("additional=.*thumbnail.*resolution".into()),
        ]))
        .match_header("X-SYNO-TOKEN", "TOK")
        .with_status(200)
        .with_body(REAL_SHAPE_PAGE)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_album_items(&t, "SID", Space::Personal, 4242, 50, 25, 4, Some("TOK"))
        .await
        .expect("album items ok");
    m.assert_async().await;
    assert_eq!(assets.len(), 1);
    let a = &assets[0];
    assert_eq!(a.id, 73609);
    assert_eq!(a.unit_id, 55932);
    assert_eq!(a.cache_key, "55932_1788825603");
    assert_eq!(a.filename, "IMG_7521.HEIC");
    assert_eq!(a.media_kind, MediaKind::Photo);
    assert_eq!(a.width, Some(3024));
    assert_eq!(a.space, Space::Personal);
}

#[tokio::test]
async fn list_album_items_empty_album_is_empty_vec() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("album_id".into(), "7".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_album_items(&t, "SID", Space::Personal, 7, 0, 100, 4, None)
        .await
        .expect("empty ok");
    assert!(assets.is_empty());
}

#[tokio::test]
async fn list_album_items_uses_team_api_for_shared_space() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded(
            "api".into(),
            "SYNO.FotoTeam.Browse.Item".into(),
        ))
        .with_status(200)
        .with_body(REAL_SHAPE_PAGE)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_album_items(&t, "SID", Space::Shared, 1, 0, 10, 4, None)
        .await
        .expect("team ok");
    m.assert_async().await;
    assert_eq!(assets[0].space, Space::Shared);
}

// Real NAS answered album_id=<nonexistent> with {"error":{"code":609}}.
#[tokio::test]
async fn list_album_items_missing_album_fails_closed() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .with_status(200)
        .with_body(r#"{"error":{"code":609},"success":false}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let res = list_album_items(&t, "SID", Space::Personal, 999999, 0, 10, 4, None).await;
    assert!(res.is_err(), "success:false must be an error, got {res:?}");
}
