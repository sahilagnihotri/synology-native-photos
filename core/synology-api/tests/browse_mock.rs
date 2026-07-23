use mockito::Matcher;
use models::{Connection, MediaKind, Space};
use synology_api::browse::{list_albums, list_items};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
        .expect("transport builds")
}

#[tokio::test]
async fn list_items_personal_parses_assets_and_ignores_unknown_fields() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()))
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":101,"filename":"a.jpg","type":"photo","time":1700000000,"filesize":2048,
             "additional":{"thumbnail":{"cache_key":"CK101"},"resolution":{"width":4000,"height":3000}},
             "unmodeled":"ignore me"},
            {"id":102,"filename":"b.mp4","type":"video","time":1700000100,
             "additional":{"thumbnail":{"cache_key":"CK102"}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1).await.expect("list ok");
    assert_eq!(assets.len(), 2);
    let a = &assets[0];
    assert_eq!(a.id, 101);
    assert_eq!(a.cache_key, "CK101");
    assert_eq!(a.filename, "a.jpg");
    assert_eq!(a.media_kind, MediaKind::Photo);
    assert_eq!(a.taken_at, Some(1700000000));
    assert_eq!(a.width, Some(4000));
    assert_eq!(a.height, Some(3000));
    assert_eq!(a.file_size, Some(2048));
    assert_eq!(a.space, Space::Personal);
    let b = &assets[1];
    assert_eq!(b.media_kind, MediaKind::Video);
    assert_eq!(b.cache_key, "CK102");
    assert_eq!(b.width, None);
}

#[tokio::test]
async fn list_items_shared_uses_fototeam_namespace() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.FotoTeam.Browse.Item".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Shared, 0, 100, 1).await.expect("list ok");
    assert!(assets.is_empty());
}

#[tokio::test]
async fn unknown_media_type_decodes_as_unknown_not_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":9,"filename":"live.heic","type":"live_photo","additional":{"thumbnail":{"cache_key":"CK9"}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1).await.expect("list ok");
    assert_eq!(assets[0].media_kind, MediaKind::Unknown);
}

#[tokio::test]
async fn extra_unknown_top_level_item_fields_still_decode() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":55,"filename":"c.jpg","type":"photo","time":1700000200,
             "owner_user_id":7,"folder_id":3,"indexed_time":1700000300,
             "additional":{"thumbnail":{"cache_key":"CK55"},"future_block":{"nested":true}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1).await.expect("list ok");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].id, 55);
    assert_eq!(assets[0].cache_key, "CK55");
}

#[tokio::test]
async fn list_items_sends_offset_and_limit() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("offset".into(), "40".into()),
            Matcher::UrlEncoded("limit".into(), "20".into()),
            Matcher::UrlEncoded("method".into(), "list".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 40, 20, 1).await.expect("list ok");
    assert!(assets.is_empty());
}

#[tokio::test]
async fn list_albums_parses_albums() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Album".into()))
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":5,"name":"Trip","item_count":42,"additional":{"thumbnail":{"cache_key":"COVER5"}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let albums = list_albums(&t, "SID", Space::Personal, 0, 100, 1).await.expect("albums ok");
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].id, 5);
    assert_eq!(albums[0].name, "Trip");
    assert_eq!(albums[0].item_count, 42);
    assert_eq!(albums[0].cover_cache_key.as_deref(), Some("COVER5"));
    assert_eq!(albums[0].space, Space::Personal);
}

#[tokio::test]
async fn list_albums_sends_offset_and_limit() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("offset".into(), "10".into()),
            Matcher::UrlEncoded("limit".into(), "5".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let albums = list_albums(&t, "SID", Space::Personal, 10, 5, 1).await.expect("albums ok");
    assert!(albums.is_empty());
}
