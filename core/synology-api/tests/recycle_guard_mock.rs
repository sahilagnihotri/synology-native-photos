//! R1-9: the recycle path guard decides what may reach File Station Delete,
//! which is unrecoverable. It must refuse when in doubt. Every network call
//! here goes to a localhost mock server, and every destructive call is a mock
//! with `expect(0)` that fails the test if it is reached.

use mockito::Matcher;
use models::CoreError;
use synology_api::recycle::{
    delete_recycle_item_with_polling, ensure_recycle_photos_path, recycle_thumbnail,
    restore_recycle_item_with_polling, TaskPolling,
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

fn fast() -> TaskPolling {
    TaskPolling {
        attempts: 2,
        interval: std::time::Duration::from_millis(1),
    }
}

const ROOT: &str = "/home/#recycle/Photos";

#[test]
fn guard_refuses_ambiguous_or_non_file_paths() {
    for bad in [
        // a bare folder inside the bin: delete would wipe the subtree
        "/home/#recycle/Photos/iPhone",
        "/home/#recycle/Photos/iPhone/2016",
        // no usable extension
        "/home/#recycle/Photos/a.",
        "/home/#recycle/Photos/.jpg",
        // a comma could split into a second path
        "/home/#recycle/Photos/a.jpg,/home/Photos/b.jpg",
        // backslash separators
        "/home/#recycle/Photos/x\\..\\..\\Photos\\a.jpg",
        // control characters
        "/home/#recycle/Photos/a\n.jpg",
        "/home/#recycle/Photos/a\r.jpg",
        "/home/#recycle/Photos/a\t.jpg",
        "/home/#recycle/Photos/a\u{7f}.jpg",
        // dot and slash lookalikes
        "/home/#recycle/Photos/\u{ff0e}\u{ff0e}/a.jpg",
        "/home/#recycle/Photos/\u{2024}\u{2024}/a.jpg",
        "/home/#recycle/Photos/x\u{ff0f}a.jpg",
        "/home/#recycle/Photos/x\u{2215}a.jpg",
        "/home/#recycle/Photos/x\u{2044}a.jpg",
        "/home/#recycle/Photos/a\u{3002}jpg",
    ] {
        assert!(ensure_recycle_photos_path(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn guard_still_accepts_ordinary_media_files() {
    for ok in [
        "/home/#recycle/Photos/a.jpg",
        "/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG",
        "/home/#recycle/Photos/dir.with.dots/..hidden.jpg",
        "/home/#recycle/Photos/\u{c5}lesund/IMG 1.HEIC",
        "/home/#recycle/Photos/clip.mov",
    ] {
        assert!(ensure_recycle_photos_path(ok).is_ok(), "{ok:?}");
    }
}

async fn delete_trap(server: &mut mockito::ServerGuard) -> mockito::Mock {
    server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"taskid":"t"}}"#)
        .expect(0)
        .create_async()
        .await
}

async fn list_parent(
    server: &mut mockito::ServerGuard,
    folder: &str,
    files: &str,
) -> mockito::Mock {
    server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.FileStation.List".into()),
            Matcher::UrlEncoded("folder_path".into(), folder.into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(format!(
            r#"{{"success":true,"data":{{"files":[{files}]}}}}"#
        ))
        .create_async()
        .await
}

#[tokio::test]
async fn delete_refuses_a_bare_recycle_folder_without_any_write() {
    let mut server = mockito::Server::new_async().await;
    let trap = delete_trap(&mut server).await;
    let t = transport_for(&server);
    let result =
        delete_recycle_item_with_polling(&t, "SID", None, "/home/#recycle/Photos/iPhone", fast())
            .await;
    assert!(result.is_err(), "got {result:?}");
    trap.assert_async().await;
}

/// A folder whose name looks like a file name passes the string guard, so
/// delete must confirm with File Station that the entry is a file.
#[tokio::test]
#[ignore = "R1-9 NEEDS RULING: delete has no is-a-file check yet"]
async fn delete_refuses_a_folder_whose_name_looks_like_a_file() {
    let mut server = mockito::Server::new_async().await;
    let _parent = list_parent(
        &mut server,
        ROOT,
        r#"{"isdir":true,"name":"2016.09","path":"/home/#recycle/Photos/2016.09"}"#,
    )
    .await;
    let trap = delete_trap(&mut server).await;
    let t = transport_for(&server);
    let result =
        delete_recycle_item_with_polling(&t, "SID", None, "/home/#recycle/Photos/2016.09", fast())
            .await;
    assert!(
        matches!(result, Err(CoreError::UnexpectedResponse { .. })),
        "got {result:?}"
    );
    trap.assert_async().await;
}

/// An entry File Station does not list is not provably a file. Refuse.
#[tokio::test]
#[ignore = "R1-9 NEEDS RULING: delete has no is-a-file check yet"]
async fn delete_refuses_an_entry_it_cannot_find() {
    let mut server = mockito::Server::new_async().await;
    let _parent = list_parent(
        &mut server,
        ROOT,
        r#"{"isdir":false,"name":"other.jpg","path":"/home/#recycle/Photos/other.jpg"}"#,
    )
    .await;
    let trap = delete_trap(&mut server).await;
    let t = transport_for(&server);
    let result =
        delete_recycle_item_with_polling(&t, "SID", None, "/home/#recycle/Photos/a.jpg", fast())
            .await;
    assert!(result.is_err(), "got {result:?}");
    trap.assert_async().await;
}

#[tokio::test]
async fn restore_refuses_a_comma_joined_path_without_any_write() {
    let mut server = mockito::Server::new_async().await;
    // Every listing answers "empty folder", so nothing but the guard stands
    // between this path and the move.
    let _any_list = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"files":[]}}"#)
        .create_async()
        .await;
    let trap = delete_trap(&mut server).await;
    let t = transport_for(&server);
    let result = restore_recycle_item_with_polling(
        &t,
        "SID",
        None,
        "/home/#recycle/Photos/a.jpg,/home/Photos/b.jpg",
        fast(),
    )
    .await;
    assert!(result.is_err(), "got {result:?}");
    trap.assert_async().await;
}

#[tokio::test]
async fn recycle_thumbnail_refuses_a_path_outside_the_bin() {
    let mut server = mockito::Server::new_async().await;
    let get = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_header("content-type", "image/jpeg")
        .with_body("LIVE-ORIGINAL")
        .expect(0)
        .create_async()
        .await;
    let t = transport_for(&server);
    let result = recycle_thumbnail(&t, "SID", None, "/home/Photos/a.jpg", "small").await;
    assert!(
        matches!(result, Err(CoreError::UnexpectedResponse { .. })),
        "got {result:?}"
    );
    get.assert_async().await;
}
