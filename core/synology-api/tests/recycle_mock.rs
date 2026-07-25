use mockito::Matcher;
use models::CoreError;
use synology_api::recycle::{
    delete_recycle_item, list_recycle_photos, recycle_thumbnail, restore_recycle_item, trigger_reindex,
};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&models::Connection {
        host: server.url(),
        verify_tls: true,
        pinned_cert_der: None,
        allow_untrusted_tls: false,
    })
    .expect("transport builds")
}

// A File Station folder listing is a GET (like browse), so these mocks match
// on the query string. The mutating calls (CopyMove/Delete/reindex) POST a
// form body, so those match on body via UrlEncoded (which decodes for us, so a
// path's slashes/`#` never have to be matched in their percent-encoded form).

// --- list_recycle_photos ------------------------------------------------

/// Mock a `SYNO.FileStation.List` for one `folder_path`, returning `body`.
fn mock_list_folder(server: &mut mockito::ServerGuard, folder_path: &str, body: &str) -> mockito::Mock {
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.List".into()),
            Matcher::UrlEncoded("method".into(), "list".into()),
            Matcher::UrlEncoded("folder_path".into(), folder_path.into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(body.to_string())
        .create()
}

#[tokio::test]
async fn list_recycle_photos_walks_recursively_and_sorts_newest_first() {
    let mut server = mockito::Server::new_async().await;
    // Root holds one subfolder; the header must ride on the read call too.
    let _root = server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.List".into()),
            Matcher::UrlEncoded("folder_path".into(), "/home/#recycle/Photos".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(
            r#"{"success":true,"data":{"files":[
                {"isdir":true,"name":"iPhone","path":"/home/#recycle/Photos/iPhone"}
            ]}}"#,
        )
        .create_async()
        .await;
    let _sub = mock_list_folder(
        &mut server,
        "/home/#recycle/Photos/iPhone",
        r#"{"success":true,"data":{"files":[
            {"isdir":false,"name":"IMG_1.JPG","path":"/home/#recycle/Photos/iPhone/IMG_1.JPG","additional":{"size":100,"time":{"mtime":1600000000}}},
            {"isdir":false,"name":"VID_1.MOV","path":"/home/#recycle/Photos/iPhone/VID_1.MOV","additional":{"size":200,"time":{"mtime":1600000100}}}
        ]}}"#,
    );

    let t = transport_for(&server);
    let items = list_recycle_photos(&t, "SID", Some("TOK"), 0, 50).await.expect("list ok");

    assert_eq!(items.len(), 2, "both files collected across the recursive walk");
    // Newest deletion (higher mtime) first.
    assert_eq!(items[0].filename, "VID_1.MOV");
    assert_eq!(items[0].deleted_at, 1_600_000_100);
    assert_eq!(items[0].file_size, 200);
    assert_eq!(items[0].media_kind, models::MediaKind::Video);
    assert_eq!(items[0].recycle_path, "/home/#recycle/Photos/iPhone/VID_1.MOV");
    assert_eq!(items[1].filename, "IMG_1.JPG");
    assert_eq!(items[1].media_kind, models::MediaKind::Photo);
}

#[tokio::test]
async fn list_recycle_photos_applies_offset_and_limit() {
    let mut server = mockito::Server::new_async().await;
    let _root = mock_list_folder(
        &mut server,
        "/home/#recycle/Photos",
        r#"{"success":true,"data":{"files":[
            {"isdir":false,"name":"A.JPG","path":"/home/#recycle/Photos/A.JPG","additional":{"size":1,"time":{"mtime":300}}},
            {"isdir":false,"name":"B.JPG","path":"/home/#recycle/Photos/B.JPG","additional":{"size":1,"time":{"mtime":200}}},
            {"isdir":false,"name":"C.JPG","path":"/home/#recycle/Photos/C.JPG","additional":{"size":1,"time":{"mtime":100}}}
        ]}}"#,
    );

    let t = transport_for(&server);
    // Sorted newest-first is A(300), B(200), C(100); offset 1 limit 1 -> [B].
    let items = list_recycle_photos(&t, "SID", None, 1, 1).await.expect("list ok");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].filename, "B.JPG");
}

#[tokio::test]
async fn list_recycle_photos_returns_empty_when_root_absent() {
    let mut server = mockito::Server::new_async().await;
    // A missing recycle folder answers with a (non-auth) error; that must fold
    // into an empty listing, not an error.
    let _root = mock_list_folder(
        &mut server,
        "/home/#recycle/Photos",
        r#"{"success":false,"error":{"code":408}}"#,
    );
    let t = transport_for(&server);
    let items = list_recycle_photos(&t, "SID", None, 0, 50).await.expect("absent root is empty, not an error");
    assert!(items.is_empty());
}

#[tokio::test]
async fn list_recycle_photos_propagates_an_auth_error() {
    let mut server = mockito::Server::new_async().await;
    let _root = mock_list_folder(
        &mut server,
        "/home/#recycle/Photos",
        r#"{"success":false,"error":{"code":400}}"#,
    );
    let t = transport_for(&server);
    let err = list_recycle_photos(&t, "SID", None, 0, 50).await.unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "a bad session must surface, got {err:?}");
}

// --- restore_recycle_item -----------------------------------------------

#[tokio::test]
async fn restore_recycle_item_moves_file_to_its_original_parent() {
    let mut server = mockito::Server::new_async().await;
    let _move = server
        .mock("POST", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK")
        .match_body(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.CopyMove".into()),
            Matcher::UrlEncoded("method".into(), "start".into()),
            Matcher::UrlEncoded("version".into(), "3".into()),
            // Derived destination: the mirrored original parent directory.
            Matcher::UrlEncoded("dest_folder_path".into(), "/home/Photos/iPhone/2016/09".into()),
            Matcher::UrlEncoded("overwrite".into(), "false".into()),
            Matcher::UrlEncoded("path".into(), r#"["/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG"]"#.into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"taskid":"FileStation_task_1"}}"#)
        .expect(1)
        .create_async()
        .await;

    let t = transport_for(&server);
    restore_recycle_item(&t, "SID", Some("TOK"), "/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG")
        .await
        .expect("restore ok");
    _move.assert_async().await;
}

#[tokio::test]
async fn restore_recycle_item_fails_closed_on_a_server_error() {
    let mut server = mockito::Server::new_async().await;
    let _move = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("method=start".into()))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = restore_recycle_item(&t, "SID", None, "/home/#recycle/Photos/a.jpg").await.unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn restore_recycle_item_refuses_a_non_recycle_path_without_any_network_call() {
    let mut server = mockito::Server::new_async().await;
    // Any request reaching the NAS for a bogus path is a bug.
    let _trap = server
        .mock("POST", "/webapi/entry.cgi")
        .expect(0)
        .with_status(200)
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = restore_recycle_item(&t, "SID", None, "/home/Photos/not-in-recycle.jpg").await.unwrap_err();
    assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    _trap.assert_async().await;
}

// --- delete_recycle_item ------------------------------------------------

#[tokio::test]
async fn delete_recycle_item_sends_filestation_delete() {
    let mut server = mockito::Server::new_async().await;
    let _del = server
        .mock("POST", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK")
        .match_body(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.Delete".into()),
            Matcher::UrlEncoded("method".into(), "start".into()),
            Matcher::UrlEncoded("version".into(), "2".into()),
            Matcher::UrlEncoded("path".into(), r#"["/home/#recycle/Photos/a.jpg"]"#.into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"taskid":"FileStation_task_2"}}"#)
        .expect(1)
        .create_async()
        .await;

    let t = transport_for(&server);
    delete_recycle_item(&t, "SID", Some("TOK"), "/home/#recycle/Photos/a.jpg").await.expect("delete ok");
    _del.assert_async().await;
}

#[tokio::test]
async fn delete_recycle_item_fails_closed_on_a_server_error() {
    let mut server = mockito::Server::new_async().await;
    let _del = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("SYNO.FileStation.Delete".into()))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":401}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = delete_recycle_item(&t, "SID", None, "/home/#recycle/Photos/a.jpg").await.unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

// --- recycle_thumbnail --------------------------------------------------

#[tokio::test]
async fn recycle_thumbnail_returns_image_bytes() {
    let mut server = mockito::Server::new_async().await;
    let payload = b"THUMB-BYTES".to_vec();
    let _thumb = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.Thumb".into()),
            Matcher::UrlEncoded("method".into(), "get".into()),
            Matcher::UrlEncoded("path".into(), "/home/#recycle/Photos/a.jpg".into()),
            Matcher::UrlEncoded("size".into(), "small".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "image/jpeg")
        .with_body(payload.clone())
        .create_async()
        .await;

    let t = transport_for(&server);
    let bytes = recycle_thumbnail(&t, "SID", None, "/home/#recycle/Photos/a.jpg", "small")
        .await
        .expect("thumb ok");
    assert_eq!(bytes, payload);
}

#[tokio::test]
async fn recycle_thumbnail_json_error_maps_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _thumb = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":401}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = recycle_thumbnail(&t, "SID", None, "/home/#recycle/Photos/a.jpg", "small").await.unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "a JSON error must not be returned as image bytes, got {err:?}");
}

// --- trigger_reindex ----------------------------------------------------

#[tokio::test]
async fn trigger_reindex_calls_foto_index() {
    let mut server = mockito::Server::new_async().await;
    let _reindex = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Foto.Index".into()),
            Matcher::UrlEncoded("method".into(), "reindex".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .expect(1)
        .create_async()
        .await;
    let t = transport_for(&server);
    trigger_reindex(&t, "SID", Some("TOK")).await.expect("reindex ok");
    _reindex.assert_async().await;
}

#[tokio::test]
async fn trigger_reindex_fails_closed_on_a_server_error() {
    let mut server = mockito::Server::new_async().await;
    let _reindex = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("method=reindex".into()))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = trigger_reindex(&t, "SID", None).await.unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}
