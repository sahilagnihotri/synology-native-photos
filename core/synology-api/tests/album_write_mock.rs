use mockito::Matcher;
use models::{CoreError, Space};
use synology_api::album_write::{add_items, create_album, delete_album, remove_items};
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

// Every write posts a form body to the shared entry.cgi dispatcher (matching
// the verified delete-probe request shape), so the mocks match on POST body
// regex, not query string.

// --- create_album -------------------------------------------------------

#[tokio::test]
async fn create_album_returns_the_new_album() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO.Foto.Browse.NormalAlbum".into()),
            Matcher::Regex("method=create".into()),
            Matcher::Regex("name=Recently".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"album":{"id":4242,"name":"Recently Deleted","item_count":0}}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let album = create_album(&t, "SID", Space::Personal, "Recently Deleted", 1, Some("TOK"))
        .await
        .expect("create ok");
    assert_eq!(album.id, 4242);
    assert_eq!(album.name, "Recently Deleted");
    assert_eq!(album.space, Space::Personal);
    assert!(!album.is_smart);
    assert!(!album.is_shared);
}

#[tokio::test]
async fn create_album_sends_syno_token_header_and_empty_item_array() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK123")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("method=create".into()),
            // item=[] url-encodes to item=%5B%5D
            Matcher::Regex("item=%5B%5D".into()),
            Matcher::Regex("_sid=SID".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"album":{"id":1,"name":"T","item_count":0}}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    create_album(&t, "SID", Space::Personal, "T", 1, Some("TOK123"))
        .await
        .expect("create ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn create_album_maps_failure_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = create_album(&t, "SID", Space::Personal, "T", 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn create_album_missing_album_payload_fails_closed() {
    // success:true but no data.album: decode_envelope fails closed.
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = create_album(&t, "SID", Space::Personal, "T", 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
}

// --- add_items ----------------------------------------------------------

#[tokio::test]
async fn add_items_success_with_empty_error_list() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO.Foto.Browse.NormalAlbum".into()),
            Matcher::Regex("method=add_item".into()),
            Matcher::Regex("id=4242".into()),
            // item=[1,2] url-encodes to item=%5B1%2C2%5D
            Matcher::Regex("item=%5B1%2C2%5D".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"error_list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    add_items(&t, "SID", Space::Personal, 4242, &[1, 2], 1, Some("TOK"))
        .await
        .expect("add_items ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn add_items_sends_syno_token_header() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_header("X-SYNO-TOKEN", "TOK123")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"error_list":[]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    add_items(&t, "SID", Space::Personal, 1, &[9], 1, Some("TOK123"))
        .await
        .expect("add_items ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn add_items_non_empty_error_list_fails_closed() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"error_list":[{"id":1,"code":123}]}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = add_items(&t, "SID", Space::Personal, 1, &[1], 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
}

#[tokio::test]
async fn add_items_maps_failure_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":401}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = add_items(&t, "SID", Space::Personal, 1, &[1], 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

// --- remove_items -------------------------------------------------------

#[tokio::test]
async fn remove_items_bare_success_is_ok() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO.Foto.Browse.NormalAlbum".into()),
            Matcher::Regex("method=delete_item".into()),
            Matcher::Regex("id=4242".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    remove_items(&t, "SID", Space::Personal, 4242, &[7], 1, Some("TOK"))
        .await
        .expect("remove_items ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn remove_items_maps_failure_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = remove_items(&t, "SID", Space::Personal, 1, &[1], 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

// --- delete_album -------------------------------------------------------

#[tokio::test]
async fn delete_album_uses_generic_album_api_and_id_array() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            // The generic .Album api, NOT .NormalAlbum, for deleting a whole album.
            Matcher::Regex("api=SYNO.Foto.Browse.Album&".into()),
            Matcher::Regex("method=delete".into()),
            // id=[4242] url-encodes to id=%5B4242%5D
            Matcher::Regex("id=%5B4242%5D".into()),
        ]))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    delete_album(&t, "SID", Space::Personal, 4242, 1, Some("TOK"))
        .await
        .expect("delete_album ok");
    _m.assert_async().await;
}

#[tokio::test]
async fn delete_album_maps_failure_to_core_error() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = delete_album(&t, "SID", Space::Personal, 1, 1, Some("TOK"))
        .await
        .unwrap_err();
    assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
}

// --- space awareness ----------------------------------------------------

#[tokio::test]
async fn create_album_shared_uses_fototeam_namespace() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("api=SYNO.FotoTeam.Browse.NormalAlbum".into()))
        .with_status(200)
        .with_header("content-type", "application/json")
        .with_body(r#"{"success":true,"data":{"album":{"id":1,"name":"T","item_count":0}}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let album = create_album(&t, "SID", Space::Shared, "T", 1, Some("TOK"))
        .await
        .expect("create ok");
    assert_eq!(album.space, Space::Shared);
    _m.assert_async().await;
}
