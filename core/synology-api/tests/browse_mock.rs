use mockito::Matcher;
use models::{Connection, MediaKind, Space};
use synology_api::browse::{list_albums, list_items};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
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
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
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
    let assets = list_items(&t, "SID", Space::Shared, 0, 100, 1, None).await.expect("list ok");
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
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
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
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
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
    let assets = list_items(&t, "SID", Space::Personal, 40, 20, 1, None).await.expect("list ok");
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
    let albums = list_albums(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("albums ok");
    assert_eq!(albums.len(), 1);
    assert_eq!(albums[0].id, 5);
    assert_eq!(albums[0].name, "Trip");
    assert_eq!(albums[0].item_count, 42);
    assert_eq!(albums[0].cover_cache_key.as_deref(), Some("COVER5"));
    assert_eq!(albums[0].space, Space::Personal);
}

#[tokio::test]
async fn one_malformed_item_is_skipped_others_still_decode() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":201,"filename":"good1.jpg","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK201"}}},
            {"identifier":"not-an-id","filename":"bad-missing-id.jpg",
             "additional":{"thumbnail":{"cache_key":"CKBAD"}}},
            {"id":202,"filename":"bad-missing-cache-key.jpg","type":"photo"},
            {"id":203,"filename":"good2.jpg","type":"video",
             "additional":{"thumbnail":{"cache_key":"CK203"}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok despite bad items");
    // Only the two well-formed items with both id and cache_key survive;
    // the item with no `id` field at all and the item missing cache_key
    // are both skipped without failing the whole call.
    assert_eq!(assets.len(), 2);
    assert_eq!(assets[0].id, 201);
    assert_eq!(assets[0].cache_key, "CK201");
    assert_eq!(assets[1].id, 203);
    assert_eq!(assets[1].cache_key, "CK203");
}

#[tokio::test]
async fn item_missing_optional_filename_still_produces_usable_asset() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":301,"type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK301"}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None)
        .await
        .expect("list ok even though filename and time are absent");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].id, 301);
    assert_eq!(assets[0].cache_key, "CK301");
    // filename defaults to the id rather than the item being dropped.
    assert_eq!(assets[0].filename, "301");
    // time is optional and simply absent, not a decode failure.
    assert_eq!(assets[0].taken_at, None);
}

#[tokio::test]
async fn one_malformed_album_is_skipped_others_still_decode() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":10,"name":"Good Album","item_count":3},
            {"identifier":"not-an-id","name":"Bad Album"},
            {"id":11,"item_count":7}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let albums = list_albums(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("albums ok despite bad entry");
    // The album with no `id` is skipped; both albums with an id survive,
    // including the one missing the optional `name`.
    assert_eq!(albums.len(), 2);
    assert_eq!(albums[0].id, 10);
    assert_eq!(albums[0].name, "Good Album");
    assert_eq!(albums[1].id, 11);
    assert_eq!(albums[1].name, "11");
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
    let albums = list_albums(&t, "SID", Space::Personal, 10, 5, 1, None).await.expect("albums ok");
    assert!(albums.is_empty());
}

#[tokio::test]
async fn list_items_sends_syno_token_header_when_present() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK123")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, Some("TOK123"))
        .await
        .expect("list ok with token header");
    assert!(assets.is_empty());
    _m.assert_async().await;
}

#[tokio::test]
async fn list_items_omits_syno_token_header_when_absent() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", Matcher::Missing)
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None)
        .await
        .expect("list ok without token header");
    assert!(assets.is_empty());
    _m.assert_async().await;
}
