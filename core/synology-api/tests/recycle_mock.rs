use mockito::Matcher;
use models::{CoreError, RecycleBinStatus};
use synology_api::recycle::{
    delete_recycle_item, delete_recycle_item_with_polling, list_recycle_photos, recycle_bin_status,
    recycle_thumbnail, restore_recycle_item, restore_recycle_item_with_polling, trigger_reindex,
    TaskPolling,
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
fn mock_list_folder(
    server: &mut mockito::ServerGuard,
    folder_path: &str,
    body: &str,
) -> mockito::Mock {
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.List".into()),
            Matcher::UrlEncoded("method".into(), "list".into()),
            Matcher::UrlEncoded("folder_path".into(), folder_path.into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(body)
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
    let items = list_recycle_photos(&t, "SID", Some("TOK"), 0, 50)
        .await
        .expect("list ok");

    assert_eq!(
        items.len(),
        2,
        "both files collected across the recursive walk"
    );
    // Newest deletion (higher mtime) first.
    assert_eq!(items[0].filename, "VID_1.MOV");
    assert_eq!(items[0].deleted_at, 1_600_000_100);
    assert_eq!(items[0].file_size, 200);
    assert_eq!(items[0].media_kind, models::MediaKind::Video);
    assert_eq!(
        items[0].recycle_path,
        "/home/#recycle/Photos/iPhone/VID_1.MOV"
    );
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
    let items = list_recycle_photos(&t, "SID", None, 1, 1)
        .await
        .expect("list ok");
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
    let items = list_recycle_photos(&t, "SID", None, 0, 50)
        .await
        .expect("absent root is empty, not an error");
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
    let err = list_recycle_photos(&t, "SID", None, 0, 50)
        .await
        .unwrap_err();
    assert!(
        matches!(err, CoreError::Auth { .. }),
        "a bad session must surface, got {err:?}"
    );
}

// --- restore_recycle_item -----------------------------------------------

/// Fast completion polling so the "never finishes" cases fail in milliseconds.
fn fast_polling() -> TaskPolling {
    TaskPolling {
        attempts: 3,
        interval: std::time::Duration::from_millis(1),
    }
}

/// Mock a `SYNO.FileStation.List` of `folder` holding files named `names`.
async fn mock_folder_files(
    server: &mut mockito::ServerGuard,
    folder: &str,
    names: &[&str],
) -> mockito::Mock {
    let files: Vec<String> = names
        .iter()
        .map(|n| format!(r#"{{"isdir":false,"name":"{n}","path":"{folder}/{n}"}}"#))
        .collect();
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.List".into()),
            Matcher::UrlEncoded("folder_path".into(), folder.into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(format!(
            r#"{{"success":true,"data":{{"files":[{}]}}}}"#,
            files.join(",")
        ))
        .create_async()
        .await
}

#[tokio::test]
async fn restore_recycle_item_moves_file_to_its_original_parent() {
    let mut server = mockito::Server::new_async().await;
    // Destination has no clash; after the move the recycle folder no longer
    // holds the file, which is what confirms the background task finished.
    let _dest = mock_folder_files(&mut server, "/home/Photos/iPhone/2016/09", &["OTHER.JPG"]).await;
    let _src = mock_folder_files(&mut server, "/home/#recycle/Photos/iPhone/2016/09", &[]).await;
    let _move = server
        .mock("POST", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK")
        .match_body(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.CopyMove".into()),
            Matcher::UrlEncoded("method".into(), "start".into()),
            Matcher::UrlEncoded("version".into(), "3".into()),
            // Derived destination: the mirrored original parent directory.
            Matcher::UrlEncoded(
                "dest_folder_path".into(),
                "/home/Photos/iPhone/2016/09".into(),
            ),
            Matcher::UrlEncoded("overwrite".into(), "false".into()),
            // Must be a MOVE, not a copy, so the file leaves #recycle.
            Matcher::UrlEncoded("remove_src".into(), "true".into()),
            Matcher::UrlEncoded(
                "path".into(),
                r#"["/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG"]"#.into(),
            ),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"taskid":"FileStation_task_1"}}"#)
        .expect(1)
        .create_async()
        .await;

    let t = transport_for(&server);
    restore_recycle_item(
        &t,
        "SID",
        Some("TOK"),
        "/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG",
    )
    .await
    .expect("restore ok");
    _move.assert_async().await;
}

#[tokio::test]
async fn restore_recycle_item_refuses_when_the_destination_already_has_that_name() {
    let mut server = mockito::Server::new_async().await;
    let _dest = mock_folder_files(&mut server, "/home/Photos/iPhone", &["IMG_1.JPG"]).await;
    // overwrite=false would skip the file silently, so no move may be sent.
    let _move_trap = server
        .mock("POST", "/webapi/entry.cgi")
        .expect(0)
        .with_status(200)
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = restore_recycle_item_with_polling(
        &t,
        "SID",
        None,
        "/home/#recycle/Photos/iPhone/IMG_1.JPG",
        fast_polling(),
    )
    .await
    .unwrap_err();
    assert!(err.to_string().contains("already exists"), "got {err:?}");
    _move_trap.assert_async().await;
}

#[tokio::test]
async fn restore_recycle_item_reports_failure_when_the_file_never_leaves_the_recycle_bin() {
    let mut server = mockito::Server::new_async().await;
    let _dest = mock_folder_files(&mut server, "/home/Photos/iPhone", &[]).await;
    // The move is accepted, but the background task never moves the file.
    let _src = mock_folder_files(&mut server, "/home/#recycle/Photos/iPhone", &["IMG_1.JPG"]).await;
    let _move = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("SYNO.FileStation.CopyMove".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"taskid":"t"}}"#)
        .expect(1)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = restore_recycle_item_with_polling(
        &t,
        "SID",
        None,
        "/home/#recycle/Photos/iPhone/IMG_1.JPG",
        fast_polling(),
    )
    .await
    .unwrap_err();
    assert!(
        err.to_string().contains("still in the recycle bin"),
        "got {err:?}"
    );
    _move.assert_async().await;
}

#[tokio::test]
async fn restore_recycle_item_treats_a_vanished_recycle_folder_as_done() {
    let mut server = mockito::Server::new_async().await;
    let _dest = mock_folder_files(&mut server, "/home/Photos/iPhone", &[]).await;
    let _src = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded(
            "folder_path".into(),
            "/home/#recycle/Photos/iPhone".into(),
        ))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":408}}"#)
        .create_async()
        .await;
    let _move = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("SYNO.FileStation.CopyMove".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"taskid":"t"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    restore_recycle_item_with_polling(
        &t,
        "SID",
        None,
        "/home/#recycle/Photos/iPhone/IMG_1.JPG",
        fast_polling(),
    )
    .await
    .expect("restore ok");
}

#[tokio::test]
async fn restore_recycle_item_fails_closed_on_a_server_error() {
    let mut server = mockito::Server::new_async().await;
    let _dest = mock_folder_files(&mut server, "/home/Photos", &[]).await;
    let _move = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("method=start".into()))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = restore_recycle_item(&t, "SID", None, "/home/#recycle/Photos/a.jpg")
        .await
        .unwrap_err();
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
    let err = restore_recycle_item(&t, "SID", None, "/home/Photos/not-in-recycle.jpg")
        .await
        .unwrap_err();
    assert!(
        matches!(err, CoreError::UnexpectedResponse { .. }),
        "got {err:?}"
    );
    _trap.assert_async().await;
}

// --- delete_recycle_item ------------------------------------------------

#[tokio::test]
async fn delete_recycle_item_sends_filestation_delete() {
    let mut server = mockito::Server::new_async().await;
    let _src = mock_folder_files(&mut server, "/home/#recycle/Photos", &["b.jpg"]).await;
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
    delete_recycle_item(&t, "SID", Some("TOK"), "/home/#recycle/Photos/a.jpg")
        .await
        .expect("delete ok");
    _del.assert_async().await;
}

#[tokio::test]
async fn delete_recycle_item_reports_failure_when_the_file_is_still_there() {
    let mut server = mockito::Server::new_async().await;
    let _src = mock_folder_files(&mut server, "/home/#recycle/Photos", &["a.jpg"]).await;
    let _del = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("SYNO.FileStation.Delete".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"taskid":"t"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = delete_recycle_item_with_polling(
        &t,
        "SID",
        None,
        "/home/#recycle/Photos/a.jpg",
        fast_polling(),
    )
    .await
    .unwrap_err();
    assert!(
        err.to_string().contains("still in the recycle bin"),
        "got {err:?}"
    );
}

#[tokio::test]
async fn delete_recycle_item_refuses_paths_outside_the_recycle_bin_without_any_network_call() {
    let mut server = mockito::Server::new_async().await;
    // A File Station Delete reaching the NAS for any of these is a live
    // original being destroyed.
    let _trap = server
        .mock("POST", "/webapi/entry.cgi")
        .expect(0)
        .with_status(200)
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    for bad in [
        "/home/Photos/iPhone/2016/09/IMG_0924.JPG",
        "/home/#recycle/Photos/../../Photos/IMG_0924.JPG",
        "/home/#recycle/Photos",
        "/home/#recycle/Photos/",
        "/home/#recycle/other/a.jpg",
        "/volume1/homes/me/Photos/a.jpg",
    ] {
        let err = delete_recycle_item(&t, "SID", None, bad).await.unwrap_err();
        assert!(
            matches!(err, CoreError::UnexpectedResponse { .. }),
            "{bad}: got {err:?}"
        );
    }
    _trap.assert_async().await;
}

#[tokio::test]
async fn restore_recycle_item_refuses_a_traversal_out_of_the_recycle_bin() {
    let mut server = mockito::Server::new_async().await;
    let _trap = server
        .mock("POST", "/webapi/entry.cgi")
        .expect(0)
        .with_status(200)
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = restore_recycle_item(&t, "SID", None, "/home/#recycle/Photos/../../Photos/a.jpg")
        .await
        .unwrap_err();
    assert!(
        matches!(err, CoreError::UnexpectedResponse { .. }),
        "got {err:?}"
    );
    _trap.assert_async().await;
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
    let err = delete_recycle_item(&t, "SID", None, "/home/#recycle/Photos/a.jpg")
        .await
        .unwrap_err();
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
    let err = recycle_thumbnail(&t, "SID", None, "/home/#recycle/Photos/a.jpg", "small")
        .await
        .unwrap_err();
    assert!(
        matches!(err, CoreError::Auth { .. }),
        "a JSON error must not be returned as image bytes, got {err:?}"
    );
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
    trigger_reindex(&t, "SID", Some("TOK"))
        .await
        .expect("reindex ok");
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

// --- recycle_bin_status -------------------------------------------------

/// Mock `SYNO.Core.User.Home get` (a GET, with the SynoToken header required,
/// like every other state read), returning `body`.
async fn mock_user_home(server: &mut mockito::ServerGuard, body: &str) -> mockito::Mock {
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.Core.User.Home".into()),
            Matcher::UrlEncoded("version".into(), "1".into()),
            Matcher::UrlEncoded("method".into(), "get".into()),
            Matcher::UrlEncoded("_sid".into(), "SID".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(body)
        .expect(1)
        .create_async()
        .await
}

#[tokio::test]
async fn recycle_bin_status_reads_enabled() {
    let mut server = mockito::Server::new_async().await;
    // The shape the real NAS returned on 2026-10-16.
    let m = mock_user_home(
        &mut server,
        r#"{"data":{"enable":true,"enable_domain":false,"enable_ldap":false,"enable_recycle_bin":true,"encryption":0,"location":"/volume1"},"success":true}"#,
    )
    .await;
    let t = transport_for(&server);
    assert_eq!(
        recycle_bin_status(&t, "SID", Some("TOK")).await.unwrap(),
        RecycleBinStatus::Enabled
    );
    m.assert_async().await;
}

#[tokio::test]
async fn recycle_bin_status_reads_disabled() {
    let mut server = mockito::Server::new_async().await;
    let _m = mock_user_home(
        &mut server,
        r#"{"data":{"enable":true,"enable_recycle_bin":false},"success":true}"#,
    )
    .await;
    let t = transport_for(&server);
    assert_eq!(
        recycle_bin_status(&t, "SID", Some("TOK")).await.unwrap(),
        RecycleBinStatus::Disabled
    );
}

#[tokio::test]
async fn recycle_bin_status_is_unknown_when_the_field_is_missing() {
    let mut server = mockito::Server::new_async().await;
    let _m = mock_user_home(&mut server, r#"{"data":{"enable":true},"success":true}"#).await;
    let t = transport_for(&server);
    assert_eq!(
        recycle_bin_status(&t, "SID", Some("TOK")).await.unwrap(),
        RecycleBinStatus::Unknown
    );
}

#[tokio::test]
async fn recycle_bin_status_is_unknown_on_a_permission_error() {
    // DSM error 105 is "permission denied", the expected answer for a
    // non-admin account.
    let mut server = mockito::Server::new_async().await;
    let _m = mock_user_home(&mut server, r#"{"success":false,"error":{"code":105}}"#).await;
    let t = transport_for(&server);
    assert_eq!(
        recycle_bin_status(&t, "SID", Some("TOK")).await.unwrap(),
        RecycleBinStatus::Unknown
    );
}

#[tokio::test]
async fn recycle_bin_status_propagates_an_auth_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = mock_user_home(&mut server, r#"{"success":false,"error":{"code":400}}"#).await;
    let t = transport_for(&server);
    let err = recycle_bin_status(&t, "SID", Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn recycle_bin_status_propagates_an_otp_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = mock_user_home(&mut server, r#"{"success":false,"error":{"code":403}}"#).await;
    let t = transport_for(&server);
    let err = recycle_bin_status(&t, "SID", Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");
}
