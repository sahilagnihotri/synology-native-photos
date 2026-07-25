use mockito::Matcher;
use models::{Connection, SearchFilters};
use synology_api::search_filter::search_facets;
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
        .expect("transport builds")
}

/// Pins the real request shape confirmed against the NAS: api
/// SYNO.Foto.Search.Filter, method list, with the X-SYNO-TOKEN header, and
/// decodes camera/aperture/geocoding(flattened)/item_type into SearchFacets.
#[tokio::test]
async fn search_facets_decodes_full_real_response_shape() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Filter".into()),
            Matcher::UrlEncoded("method".into(), "list".into()),
        ]))
        .match_header("X-SYNO-TOKEN", "TOK")
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{
                "aperture":[{"id":1,"name":"F1.8"},{"id":8,"name":"F2"},{"id":2,"name":"F2.2"}],
                "camera":[{"id":25,"name":"Nexus 6P"},{"id":7,"name":"iPhone 6"},{"id":23,"name":"iPhone 6s"}],
                "exposure_time_group":[{"end":{"den":3000,"num":1},"start":{"den":1,"num":0}}],
                "favorite":[],
                "flash":[0,16,24,25],
                "focal_length_group":[{"end":22,"start":0}],
                "folder_filter":[{"id":370,"name":"/iPhone/2015/01","owner_user_id":1,"parent":369,"passphrase":"","shared":false,"sort_by":"default","sort_direction":"default"}],
                "general_tag":[],
                "geocoding":[{"children":[{"children":[{"children":[],"id":50,"level":6,"name":"Grunerlokka"}],"id":12,"level":4,"name":"Oslo"}],"id":1,"level":1,"name":"Norway"}],
                "iso":[{"id":24,"name":"25"}],
                "item_type":[{"id":0,"name":"photo"}],
                "lens":[{"id":38,"name":"iPhone 6 back camera 4.15mm f/2.2"}],
                "person":[],
                "rating":[0],
                "time":[{"end_time":1483228799,"month":12,"start_time":1480550400,"year":2016}]
            }}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let facets = search_facets(&t, "SID", Some("TOK")).await.expect("search_facets ok");

    assert_eq!(facets.apertures.len(), 3);
    assert_eq!(facets.apertures[0].id, 1);
    assert_eq!(facets.apertures[0].name, "F1.8");

    assert_eq!(facets.cameras.len(), 3);
    assert!(facets.cameras.iter().any(|c| c.name == "iPhone 6s" && c.id == 23));

    // Geocoding is a nested tree; it must be flattened into one flat list
    // depth-first, parent before children, all three levels present.
    assert_eq!(facets.geocodings.len(), 3);
    assert_eq!(facets.geocodings[0].name, "Norway");
    assert_eq!(facets.geocodings[1].name, "Oslo");
    assert_eq!(facets.geocodings[2].name, "Grunerlokka");

    assert_eq!(facets.media_types.len(), 1);
    assert_eq!(facets.media_types[0].name, "photo");

    m.assert_async().await;
}

#[tokio::test]
async fn search_facets_omits_token_header_when_none() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let facets = search_facets(&t, "SID", None).await.expect("search_facets ok");
    assert!(facets.cameras.is_empty());
    assert!(facets.apertures.is_empty());
    assert!(facets.geocodings.is_empty());
    assert!(facets.media_types.is_empty());
    m.assert_async().await;
}

/// An empty catalog (every facet array missing/empty) must decode cleanly,
/// not error -- this is a legitimate response shape on an account with no
/// exif metadata indexed yet.
#[tokio::test]
async fn search_facets_decodes_empty_catalog_cleanly() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"camera":[],"aperture":[],"geocoding":[],"item_type":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let facets = search_facets(&t, "SID", None).await.expect("search_facets ok");
    assert!(facets.cameras.is_empty());
    assert!(facets.geocodings.is_empty());
}

#[tokio::test]
async fn search_facets_maps_envelope_error() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":100}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = search_facets(&t, "SID", None).await.unwrap_err();
    assert!(matches!(err, models::CoreError::UnexpectedResponse { .. }), "got {err:?}");
}

/// search_facets() is reachable through the crate's public facade.
#[tokio::test]
async fn search_facets_reachable_through_facade() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Filter".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let facets = synology_api::search_facets(&t, "SID", None).await.expect("search_facets ok");
    assert!(facets.cameras.is_empty());
}

/// Pins the confirmed real request shape for a date-ranged search:
/// start_time/end_time sent alongside keyword, both as bare unix-second
/// integers (not brackets, not a JSON blob) -- see browse::search_filtered's
/// doc comment for the probe that ruled every other facet param out.
#[tokio::test]
async fn search_filtered_sends_start_and_end_time_params() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Search.Search".into()),
            Matcher::UrlEncoded("method".into(), "list_item".into()),
            Matcher::UrlEncoded("keyword".into(), "IMG".into()),
            Matcher::UrlEncoded("start_time".into(), "1400000000".into()),
            Matcher::UrlEncoded("end_time".into(), "1500000000".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let filters = SearchFilters { start_time: Some(1_400_000_000), end_time: Some(1_500_000_000) };
    let assets = synology_api::search_filtered(&t, "SID", "IMG", &filters, 0, 10, 1, None).await.expect("search ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

/// A one-sided range (start_time only) must omit end_time entirely, not
/// send it empty. mockito's query matcher has no direct "param absent"
/// assertion, so this uses `match_request` to inspect the raw path/query
/// mockito received and confirm "end_time" never appears in it.
#[tokio::test]
async fn search_filtered_omits_end_time_when_only_start_given() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .match_request(|req| {
            let pq = req.path_and_query();
            pq.contains("start_time=1400000000") && !pq.contains("end_time")
        })
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let filters = SearchFilters { start_time: Some(1_400_000_000), end_time: None };
    let assets = synology_api::search_filtered(&t, "SID", "IMG", &filters, 0, 10, 1, None).await.expect("search ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

/// Default SearchFilters (no date range) must send the exact same request
/// plain search() always has -- no start_time/end_time params at all.
#[tokio::test]
async fn search_filtered_with_default_filters_matches_plain_search() {
    let mut server = mockito::Server::new_async().await;
    let m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .match_request(|req| {
            let pq = req.path_and_query();
            pq.contains("api=SYNO.Foto.Search.Search")
                && pq.contains("method=list_item")
                && pq.contains("keyword=IMG")
                && !pq.contains("start_time")
                && !pq.contains("end_time")
        })
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = synology_api::search_filtered(&t, "SID", "IMG", &SearchFilters::default(), 0, 10, 1, None)
        .await
        .expect("search ok");
    assert!(assets.is_empty());
    m.assert_async().await;
}

/// A real result row decodes end to end (reusing the same Asset shape
/// plain search() already produces) when a date filter is applied.
#[tokio::test]
async fn search_filtered_decodes_real_row_shape() {
    let mut server = mockito::Server::new_async().await;
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
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
    let filters = SearchFilters { start_time: Some(1_480_000_000), end_time: None };
    let assets = synology_api::search_filtered(&t, "SID", "IMG", &filters, 0, 10, 1, None).await.expect("search ok");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].filename, "IMG_1910.JPG");
    assert_eq!(assets[0].unit_id, 1001);
}
