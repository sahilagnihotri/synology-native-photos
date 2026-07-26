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
             "additional":{"thumbnail":{"cache_key":"CK101","unit_id":55805},"resolution":{"width":4000,"height":3000}},
             "unmodeled":"ignore me"},
            {"id":102,"filename":"b.mp4","type":"video","time":1700000100,
             "additional":{"thumbnail":{"cache_key":"CK102","unit_id":55900}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 2);
    let a = &assets[0];
    assert_eq!(a.id, 101);
    assert_eq!(a.unit_id, 55805);
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
    assert_eq!(b.unit_id, 55900);
    assert_eq!(b.cache_key, "CK102");
    assert_eq!(b.width, None);
}

/// The proven root cause: unit_id, not the item id, is what the thumbnail
/// endpoint needs. This pins the decode against the exact real-NAS shape
/// captured in the fix brief (item id=73459, unit_id=55805, cache_key
/// "55805_1483199977") so a future regression in field naming is caught here
/// rather than downstream in a blank-thumbnail bug report.
#[tokio::test]
async fn list_items_decodes_unit_id_distinct_from_item_id() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":73459,"filename":"real.jpg","type":"photo",
             "additional":{"thumbnail":{"cache_key":"55805_1483199977","unit_id":55805}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 1);
    assert_eq!(assets[0].id, 73459);
    assert_eq!(assets[0].unit_id, 55805);
    assert_ne!(assets[0].unit_id, assets[0].id, "unit_id must not be confused with the item id");
}

/// An item whose `additional.thumbnail` is missing `unit_id` must still be
/// imported (not dropped, so the grid count stays correct) with unit_id
/// defaulted to 0, per the brief: dropping it would repeat the earlier
/// over-aggressive-skip mistake.
#[tokio::test]
async fn list_items_missing_unit_id_defaults_to_zero_without_dropping_item() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":401,"filename":"no-unit-id.jpg","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK401"}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None)
        .await
        .expect("list ok even though unit_id is absent");
    assert_eq!(assets.len(), 1, "item missing unit_id must still be imported");
    assert_eq!(assets[0].id, 401);
    assert_eq!(assets[0].unit_id, 0);
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

/// A Live Photo is TWO items sharing one capture (VERIFIED against the real
/// NAS): a still `.JPG` (type=live, live_type=photo) and a motion `.MOV`
/// (type=live, live_type=video). The `.MOV` must classify as Video so the app
/// routes it to the player and shows the grid play badge; the `.JPG` stays
/// Photo. A `live` item with no `live_type` at all defaults to Photo (the
/// still component is the safe fallback). This is the end-to-end wire decode
/// proving `RawItem.live_type` flows through `parse_media_kind` into the Asset.
#[tokio::test]
async fn live_photo_components_classify_by_live_type() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":501,"filename":"IMG_0501.JPG","type":"live","live_type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK501","unit_id":5010}}},
            {"id":502,"filename":"IMG_0501.MOV","type":"live","live_type":"video",
             "additional":{"thumbnail":{"cache_key":"CK502","unit_id":5020}}},
            {"id":503,"filename":"IMG_0503.HEIC","type":"live",
             "additional":{"thumbnail":{"cache_key":"CK503","unit_id":5030}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 3);
    assert_eq!(assets[0].media_kind, MediaKind::Photo, "live still .JPG stays Photo");
    assert_eq!(assets[1].media_kind, MediaKind::Video, "live motion .MOV becomes Video");
    assert_eq!(assets[2].media_kind, MediaKind::Photo, "live with no live_type defaults to Photo");
}

/// A photo carrying the enriched `additional` blocks (exif/description/
/// rating) must decode every field onto the Asset. VERIFIED shapes: EXIF
/// values are strings, rating is an int 0..5, description is a string.
#[tokio::test]
async fn item_decodes_exif_description_and_rating() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":601,"filename":"IMG_0601.HEIC","type":"photo",
             "additional":{
               "thumbnail":{"cache_key":"CK601","unit_id":6010},
               "resolution":{"width":4032,"height":3024},
               "description":"sunset over the fjord",
               "rating":4,
               "exif":{"camera":"Apple iPhone 12","aperture":"f/1.8",
                       "exposure_time":"1/120","focal_length":"26 mm",
                       "iso":"100","lens":"iPhone 12 back camera 4.2mm f/1.6"}
             }}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 1);
    let a = &assets[0];
    assert_eq!(a.rating, 4);
    assert_eq!(a.description, "sunset over the fjord");
    assert_eq!(a.camera, "Apple iPhone 12");
    assert_eq!(a.aperture, "f/1.8");
    assert_eq!(a.exposure_time, "1/120");
    assert_eq!(a.focal_length, "26 mm");
    assert_eq!(a.iso, "100");
    assert_eq!(a.lens, "iPhone 12 back camera 4.2mm f/1.6");
    // A photo has no video_meta: those fields stay empty.
    assert_eq!(a.duration, "");
    assert_eq!(a.video_codec, "");
}

/// A video carrying `video_meta` must decode the raw duration/framerate/
/// codec/container onto the Asset. `duration`/`framerate` are tolerated as
/// either numbers or strings and stored raw; unsurfaced video_meta fields
/// (audio_codec, bitrate, ...) are ignored, not fatal.
#[tokio::test]
async fn video_decodes_video_meta() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":602,"filename":"IMG_0602.MOV","type":"video",
             "additional":{
               "thumbnail":{"cache_key":"CK602","unit_id":6020},
               "video_meta":{"duration":30000,"framerate":"29.97",
                             "video_codec":"hevc","container_type":"mov",
                             "audio_codec":"aac","bitrate":12345678}
             }}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 1);
    let a = &assets[0];
    assert_eq!(a.media_kind, MediaKind::Video);
    // duration arrived as a JSON number; it is stored raw, stringified.
    assert_eq!(a.duration, "30000");
    assert_eq!(a.framerate, "29.97");
    assert_eq!(a.video_codec, "hevc");
    assert_eq!(a.container_type, "mov");
}

/// An item that omits every enrichment block entirely must still decode, with
/// the metadata fields defaulting gracefully (empty strings / rating 0) rather
/// than failing the item.
#[tokio::test]
async fn item_missing_enrichment_blocks_defaults_gracefully() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":603,"filename":"IMG_0603.JPG","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK603","unit_id":6030}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 1);
    let a = &assets[0];
    assert_eq!(a.rating, 0);
    assert_eq!(a.description, "");
    assert_eq!(a.camera, "");
    assert_eq!(a.iso, "");
    assert_eq!(a.duration, "");
    assert_eq!(a.framerate, "");
}

/// `additional.gps` carries per-photo latitude/longitude (VERIFIED shape:
/// {"latitude": f64, "longitude": f64}). A located item decodes both onto the
/// Asset as `Some`; an item that omits the gps block decodes to `None`/`None`
/// rather than failing the item (the future Map view plots only the located
/// subset).
#[tokio::test]
async fn item_decodes_gps_and_defaults_none_when_absent() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":701,"filename":"IMG_0701.JPG","type":"photo",
             "additional":{
               "thumbnail":{"cache_key":"CK701","unit_id":7010},
               "gps":{"latitude":1.5,"longitude":2.5}
             }},
            {"id":702,"filename":"IMG_0702.JPG","type":"photo",
             "additional":{"thumbnail":{"cache_key":"CK702","unit_id":7020}}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let assets = list_items(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("list ok");
    assert_eq!(assets.len(), 2);
    let located = assets.iter().find(|a| a.id == 701).expect("located item present");
    assert_eq!(located.latitude, Some(1.5));
    assert_eq!(located.longitude, Some(2.5));
    let unlocated = assets.iter().find(|a| a.id == 702).expect("unlocated item present");
    assert_eq!(unlocated.latitude, None);
    assert_eq!(unlocated.longitude, None);
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
            {"id":5,"name":"Trip","item_count":42,"additional":{"thumbnail":{"cache_key":"COVER5","unit_id":55805}}}
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
    assert_eq!(albums[0].cover_unit_id, Some(55805));
    assert_eq!(albums[0].space, Space::Personal);
    // Neither a condition nor a sharing_info marker was present, so this
    // must decode as a normal, unshared album, not fail or default true.
    assert!(!albums[0].is_smart);
    assert!(!albums[0].is_shared);
}

/// A smart (condition) album carries a `condition` object; a shared album
/// carries a `sharing_info` object. Presence alone (regardless of either
/// object's own inner shape, unverified against real non-empty data) is
/// what this crate treats as the marker, per `RawAlbum`'s doc comment.
#[tokio::test]
async fn list_albums_detects_smart_and_shared_markers() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("api".into(), "SYNO.Foto.Browse.Album".into()))
        .with_status(200)
        .with_body(
            r#"{"success":true,"data":{"list":[
            {"id":9,"name":"Sunsets","item_count":12,
             "condition":{"time":{"start":0}},
             "sharing_info":{"enabled":true,"role":"viewer"}}
        ]}}"#,
        )
        .create_async()
        .await;
    let t = transport_for(&server);
    let albums = list_albums(&t, "SID", Space::Personal, 0, 100, 1, None).await.expect("albums ok");
    assert_eq!(albums.len(), 1);
    assert!(albums[0].is_smart, "a condition object must mark the album as smart");
    assert!(albums[0].is_shared, "a sharing_info object must mark the album as shared");
    // No thumbnail additional at all: cover fields must default cleanly,
    // not fail decode.
    assert_eq!(albums[0].cover_cache_key, None);
    assert_eq!(albums[0].cover_unit_id, None);
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
