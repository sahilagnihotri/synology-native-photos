use mockito::Matcher;
use models::Connection;
use synology_api::auth::{login, logout};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None })
        .expect("transport builds")
}

#[tokio::test]
async fn login_success_returns_session_with_sid_and_token() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.API.Auth".into()),
            Matcher::UrlEncoded("method".into(), "login".into()),
            Matcher::UrlEncoded("account".into(), "photouser".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"ABC123","synotoken":"TKN9","did":"DEV1","extra":"ignored"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", None).await.expect("login ok");
    assert_eq!(session.sid, "ABC123");
    assert_eq!(session.syno_token.as_deref(), Some("TKN9"));
    assert_eq!(session.device_did.as_deref(), Some("DEV1"));
    assert_eq!(session.username, "photouser");
}

#[tokio::test]
async fn login_without_otp_when_2fa_required_returns_otp_required() {
    let mut server = mockito::Server::new_async().await;
    // Trap mock: if login() ever sent otp_code (even empty), this one would
    // match instead and return success, failing the assertion below. This
    // proves login() omits the otp_code param entirely when None is passed.
    let _trap = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Regex("otp_code".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SHOULD_NOT_HAPPEN"}}"#)
        .expect(0)
        .create_async()
        .await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.API.Auth".into()),
            Matcher::UrlEncoded("method".into(), "login".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":403}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = login(&t, "photouser", "pw", None).await.unwrap_err();
    assert!(matches!(err, models::CoreError::OtpRequired), "got {err:?}");
    _trap.assert_async().await;
}

#[tokio::test]
async fn login_with_otp_code_succeeds() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("otp_code".into(), "654321".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"OTPSID"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", Some("654321")).await.expect("otp login ok");
    assert_eq!(session.sid, "OTPSID");
    assert_eq!(session.syno_token, None);
    assert_eq!(session.device_did, None);
}

#[tokio::test]
async fn login_bad_credentials_maps_to_auth() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = login(&t, "photouser", "wrong", None).await.unwrap_err();
    assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
}

#[tokio::test]
async fn logout_is_idempotent_on_400() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::UrlEncoded("method".into(), "logout".into()))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    logout(&t, "ABC123").await.expect("logout treats 400 as already-out");
}

#[tokio::test]
async fn logout_sends_sid_and_method() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("GET", "/webapi/entry.cgi")
        .match_query(Matcher::AllOf(vec![
            Matcher::UrlEncoded("api".into(), "SYNO.API.Auth".into()),
            Matcher::UrlEncoded("method".into(), "logout".into()),
            Matcher::UrlEncoded("_sid".into(), "ABC123".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    logout(&t, "ABC123").await.expect("logout ok");
}
