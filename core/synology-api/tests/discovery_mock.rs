use mockito::Matcher;
use models::{Connection, Space};
use synology_api::browse::{list_items_filtered, CollectionFilter};
use synology_api::discovery::{list_people, list_places, list_subjects, list_tags};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
        .expect("transport builds")
}

#[tokio::test]
async fn list_items_filtered_by_person_sends_bare_int_person_id() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
            Matcher::UrlEncoded("person_id".into(), "12279".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":73501,"filename":"IMG_1664.JPG","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK1","unit_id":55847}}}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items_filtered(&t, "SID", CollectionFilter::Person(12279), 0, 100, 1, None)
        .await
        .expect("filtered list ok");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].id, 73501);
    m.assert_async().await;
}

#[tokio::test]
async fn list_items_filtered_by_place_sends_bare_int_geocoding_id_not_array() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
            // Bare int, NOT "[756]": DSM rejects the array form (error 120,
            // reason "type") on the real NAS, confirmed during the
            // discovery-browse probe.
            Matcher::UrlEncoded("geocoding_id".into(), "756".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":73493,"filename":"IMG_1737.JPG","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK2","unit_id":55839}}}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items_filtered(&t, "SID", CollectionFilter::Place(756), 0, 100, 1, None)
        .await
        .expect("filtered list ok");
    assert_eq!(assets.len(), 1);
    m.assert_async().await;
}

#[tokio::test]
async fn list_items_filtered_by_tag_sends_bare_int_general_tag_id() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("general_tag_id".into(), "5".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items_filtered(&t, "SID", CollectionFilter::Tag(5), 0, 100, 1, None)
        .await
        .expect("filtered list ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

#[tokio::test]
async fn list_items_filtered_by_favorites_sends_favorite_true() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("favorite".into(), "true".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":73459,"filename":"IMG_1910.JPG","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK3","unit_id":55805}}}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items_filtered(&t, "SID", CollectionFilter::Favorites, 0, 100, 1, None)
        .await
        .expect("filtered list ok");
    assert_eq!(assets.len(), 1);
    m.assert_async().await;
}

/// VERIFIED against the real NAS: `album_id` is a genuinely checked filter
/// (a made-up id answers with synology error 609, not a silently-ignored
/// param), sent as a bare int, same shape as every other CollectionFilter
/// variant. Covers both normal and smart albums, since both share the one
/// `Browse.Album` list surface.
#[tokio::test]
async fn list_items_filtered_by_album_sends_bare_int_album_id() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
            Matcher::UrlEncoded("album_id".into(), "42".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[
            {"id":73501,"filename":"IMG_1664.JPG","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK1","unit_id":55847}}}
        ]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items_filtered(&t, "SID", CollectionFilter::Album(42), 0, 100, 1, None)
        .await
        .expect("filtered list ok");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].id, 73501);
    m.assert_async().await;
}

#[tokio::test]
async fn list_items_filtered_always_targets_personal_space() {
    // Verified only against SYNO.Foto.Browse.Item; the filter always
    // resolves to the personal-space API name regardless of any other
    // input, since there is no confirmed shared-space discovery browse yet.
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    list_items_filtered(&t, "SID", CollectionFilter::Favorites, 0, 100, 1, None).await.expect("ok");
    m.assert_async().await;
}

#[tokio::test]
async fn list_items_filtered_sends_token_header_when_present() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("person_id".into(), "1".into()))
        .match_header("X-SYNO-TOKEN", "TOK")
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    list_items_filtered(&t, "SID", CollectionFilter::Person(1), 0, 100, 1, Some("TOK"))
        .await
        .expect("filtered list with token header should decode ok");
    m.assert_async().await;
}

// --- Cross-module smoke: listers reachable through the public facade -----

#[tokio::test]
async fn discovery_listers_are_reachable_together() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Person".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Geocoding".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.GeneralTag".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Concept".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    assert!(list_people(&t, "SID", 0, 10, 1, None).await.unwrap().is_empty());
    assert!(list_places(&t, "SID", 0, 10, 1, None).await.unwrap().is_empty());
    assert!(list_tags(&t, "SID", 0, 10, 1, None).await.unwrap().is_empty());
    assert!(list_subjects(&t, "SID", 0, 10, 1, None).await.unwrap().is_empty());
    let _ = Space::Personal;
}
