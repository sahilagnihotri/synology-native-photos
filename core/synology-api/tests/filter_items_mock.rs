use mockito::Matcher;
use models::{Connection, MediaKind, Space};
use synology_api::browse::filter_items;
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
        .expect("transport builds")
}

/// Pins the confirmed real request shape for a combined People + Geolocation +
/// date filter: person_id, geocoding_id, start_time and end_time are all sent
/// as bare unix-second / id integers (not brackets, not a JSON blob) on
/// SYNO.Foto.Browse.Item method=list, carrying ITEM_ADDITIONAL and the
/// X-SYNO-TOKEN header. The `type` param must NOT be sent (file type stays a
/// local filter; see browse::filter_items' doc comment).
#[tokio::test]
async fn filter_items_sends_all_set_params_and_omits_type() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()),
            Matcher::UrlEncoded("method".into(), "list".into()),
            Matcher::UrlEncoded("person_id".into(), "42".into()),
            Matcher::UrlEncoded("geocoding_id".into(), "768".into()),
            Matcher::UrlEncoded("start_time".into(), "1400000000".into()),
            Matcher::UrlEncoded("end_time".into(), "1500000000".into()),
        ]))
        .match_header("X-SYNO-TOKEN", "TOK")
        .match_request(|req| {
            // The quirky `type` param is never sent (verified: type=photo
            // returns everything on this NAS), and additional carries the
            // enriched key set.
            let pq = req.path_and_query();
            !pq.contains("type=") && pq.contains("additional=")
        })
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
                {"id":73459,"filename":"IMG_1910.JPG","type":"photo","filesize":470116,"time":1483203577,
                 "additional":{"thumbnail":{"cache_key":"CK1","unit_id":1001},"resolution":{"width":3024,"height":4032}}}
            ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = filter_items(
        &t,
        "SID",
        Space::Personal,
        Some(1_400_000_000),
        Some(1_500_000_000),
        Some(42),
        Some(768),
        0,
        100,
        2,
        Some("TOK"),
    )
    .await
    .expect("filter ok");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].id, 73459);
    assert_eq!(assets[0].unit_id, 1001);
    assert_eq!(assets[0].cache_key, "CK1");
    assert_eq!(assets[0].media_kind, MediaKind::Photo);
    assert_eq!(assets[0].space, Space::Personal);
    m.assert_async().await;
}

/// Only the set narrowing params appear: a geolocation-only filter sends
/// geocoding_id and omits person_id / start_time / end_time entirely (never
/// as empty strings).
#[tokio::test]
async fn filter_items_geocoding_only_omits_the_unset_params() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .match_request(|req| {
            let pq = req.path_and_query();
            pq.contains("geocoding_id=768")
                && !pq.contains("person_id")
                && !pq.contains("start_time")
                && !pq.contains("end_time")
                && !pq.contains("type=")
        })
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = filter_items(&t, "SID", Space::Personal, None, None, None, Some(768), 0, 100, 2, None)
        .await
        .expect("filter ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

/// A person-only filter sends person_id and omits geocoding_id and the date
/// range.
#[tokio::test]
async fn filter_items_person_only_omits_the_unset_params() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .match_request(|req| {
            let pq = req.path_and_query();
            pq.contains("person_id=42")
                && !pq.contains("geocoding_id")
                && !pq.contains("start_time")
                && !pq.contains("end_time")
        })
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = filter_items(&t, "SID", Space::Personal, None, None, Some(42), None, 0, 100, 2, None)
        .await
        .expect("filter ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

/// With every narrowing param `None`, the request is a plain Browse.Item list
/// for the space: no person_id / geocoding_id / start_time / end_time / type
/// at all.
#[tokio::test]
async fn filter_items_with_no_params_is_a_plain_list() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .match_request(|req| {
            let pq = req.path_and_query();
            pq.contains("api=SYNO.Foto.Browse.Item")
                && pq.contains("method=list")
                && !pq.contains("person_id")
                && !pq.contains("geocoding_id")
                && !pq.contains("start_time")
                && !pq.contains("end_time")
                && !pq.contains("type=")
        })
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = filter_items(&t, "SID", Space::Personal, None, None, None, None, 0, 100, 2, None)
        .await
        .expect("filter ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

#[tokio::test]
async fn filter_items_maps_envelope_error() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":100}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = filter_items(&t, "SID", Space::Personal, None, None, Some(42), None, 0, 100, 2, None)
        .await
        .unwrap_err();
    assert!(matches!(err, models::CoreError::UnexpectedResponse { .. }), "got {err:?}");
}

/// Reachable through the crate's public facade, same smoke pattern as the
/// search/discovery reexport checks.
#[tokio::test]
async fn filter_items_reachable_through_facade() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Item".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    assert!(synology_api::filter_items(&t, "SID", Space::Personal, None, None, None, Some(1), 0, 10, 2, None)
        .await
        .unwrap()
        .is_empty());
}
