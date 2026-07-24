use mockito::Matcher;
use models::Connection;
use synology_api::auth::{login, logout};
use synology_api::transport::Transport;

fn transport_for(server: &mockito::ServerGuard) -> Transport {
    Transport::new(&Connection { host: server.url(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false })
        .expect("transport builds")
}

/// Every login test in this file mocks a POST to /webapi/entry.cgi and
/// matches on the URL-encoded form BODY, never the query string: this is
/// itself part of proving section D (login params go in the POST form body).
/// A mock that matched the query string instead would simply never fire,
/// failing the test with a connection/404-style error rather than silently
/// passing, so these tests double as a regression guard against login ever
/// reverting to a query-string GET.

#[tokio::test]
async fn login_success_returns_session_with_sid_and_token() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO\\.API\\.Auth".into()),
            Matcher::Regex("method=login".into()),
            Matcher::Regex("account=photouser".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"ABC123","synotoken":"TKN9","did":"DEV1","extra":"ignored"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", None, None).await.expect("login ok");
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
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("otp_code".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SHOULD_NOT_HAPPEN"}}"#)
        .expect(0)
        .create_async()
        .await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO\\.API\\.Auth".into()),
            Matcher::Regex("method=login".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":403}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = login(&t, "photouser", "pw", None, None).await.unwrap_err();
    assert!(matches!(err, models::CoreError::OtpRequired), "got {err:?}");
    _trap.assert_async().await;
}

#[tokio::test]
async fn login_with_otp_code_succeeds() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("otp_code=654321".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"OTPSID"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", Some("654321"), None).await.expect("otp login ok");
    assert_eq!(session.sid, "OTPSID");
    assert_eq!(session.syno_token, None);
    assert_eq!(session.device_did, None);
}

#[tokio::test]
async fn login_with_otp_sends_enable_device_token_and_device_name() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("otp_code=654321".into()),
            Matcher::Regex("enable_device_token=yes".into()),
            Matcher::Regex("device_name=".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"OTPSID"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    login(&t, "photouser", "pw", Some("654321"), None).await.expect("otp login with device-trust request ok");
}

#[tokio::test]
async fn login_without_otp_never_sends_enable_device_token() {
    let mut server = mockito::Server::new_async().await;
    let _trap = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("enable_device_token".into()))
        .expect(0)
        .create_async()
        .await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("method=login".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SID"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    login(&t, "photouser", "pw", None, None).await.expect("plain login ok");
    _trap.assert_async().await;
}

// --- Section E: device-token 2FA (trust this device) ---------------------

#[tokio::test]
async fn login_with_otp_and_enable_device_token_stores_returned_token() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("otp_code=111111".into()),
            Matcher::Regex("enable_device_token=yes".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SID-FIRST","did":"DEVICE-TOKEN-XYZ"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", Some("111111"), None).await.expect("first login with otp ok");
    assert_eq!(session.device_did.as_deref(), Some("DEVICE-TOKEN-XYZ"), "the returned device token must be captured onto Session.device_did so the caller can persist it");
}

#[tokio::test]
async fn login_with_otp_decodes_device_id_field_name_too() {
    // DSM's exact field name (did vs device_id) is unverified; this proves
    // the tolerant decode also picks up the alternate name.
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("otp_code=222222".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SID-ALT","device_id":"DEVICE-TOKEN-ALT"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", Some("222222"), None).await.expect("login ok");
    assert_eq!(session.device_did.as_deref(), Some("DEVICE-TOKEN-ALT"));
}

#[tokio::test]
async fn later_login_with_stored_device_token_succeeds_without_otp() {
    let mut server = mockito::Server::new_async().await;
    // Trap: a later login must never need to send otp_code once a device
    // token is presented.
    let _trap = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("otp_code".into()))
        .expect(0)
        .create_async()
        .await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("method=login".into()),
            Matcher::Regex("did=DEVICE-TOKEN-XYZ".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SID-TRUSTED"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let session = login(&t, "photouser", "pw", None, Some("DEVICE-TOKEN-XYZ"))
        .await
        .expect("login with a trusted device token should succeed without an otp_code");
    assert_eq!(session.sid, "SID-TRUSTED");
    _trap.assert_async().await;
}

#[tokio::test]
async fn login_with_device_token_sends_both_candidate_param_names() {
    // Param name is unverified against the real DSM (did vs device_id); the
    // client sends both so whichever one this DSM reads is honored.
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("did=DEVICE-TOKEN-XYZ".into()),
            Matcher::Regex("device_id=DEVICE-TOKEN-XYZ".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SID-BOTH"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    login(&t, "photouser", "pw", None, Some("DEVICE-TOKEN-XYZ")).await.expect("login ok");
}

#[tokio::test]
async fn login_with_stale_device_token_falls_back_to_otp_required() {
    // DSM rejecting an expired/unknown device token looks exactly like a
    // login with no 2FA credential at all: this must fail closed into
    // OtpRequired, never silently grant a session.
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("did=STALE-TOKEN".into()))
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":403}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = login(&t, "photouser", "pw", None, Some("STALE-TOKEN")).await.unwrap_err();
    assert!(matches!(err, models::CoreError::OtpRequired), "a rejected device token must fall back to OtpRequired, got {err:?}");
}

#[tokio::test]
async fn login_bad_credentials_maps_to_auth() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Any)
        .with_status(200)
        .with_body(r#"{"success":false,"error":{"code":400}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    let err = login(&t, "photouser", "wrong", None, None).await.unwrap_err();
    assert!(matches!(err, models::CoreError::Auth { .. }), "got {err:?}");
}

// --- Section D: login params never in the URL, never leaked in errors ----

#[tokio::test]
async fn login_params_are_sent_in_the_post_body_not_the_url() {
    let mut server = mockito::Server::new_async().await;
    // Matches only on the body; a query-string-based implementation would
    // still hit this mock's path but the body match would simply be trivially
    // true for an empty body, so the real proof is the companion assertion
    // in login_error_never_contains_password_or_field_name below (a
    // connection failure's error text is inspected directly). This test
    // additionally locks down that the mock only matches when passwd is in
    // the body.
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("passwd=my-s3cret-pw".into()))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{"sid":"SID"}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    login(&t, "photouser", "my-s3cret-pw", None, None).await.expect("login ok, proving passwd travelled in the body the mock matched");
}

#[tokio::test]
async fn login_error_never_contains_password_or_field_name() {
    // Point at a host nothing is listening on, so the request fails at the
    // transport level. The resulting error (and everything transport.rs
    // could hand back) must never mention the password value or even the
    // literal field name "passwd" - if either did, that alone proves a leak
    // even if the value differs from the raw password.
    let connection = Connection { host: "https://127.0.0.1:1".to_string(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false };
    let t = Transport::new(&connection).expect("transport builds");
    let password = "s3cr3t-do-not-leak-me";
    let err = login(&t, "photouser", password, None, None).await.unwrap_err();
    let message = err.to_string();
    assert!(!message.contains(password), "error message must not contain the password: {message}");
    assert!(!message.to_lowercase().contains("passwd"), "error message must not contain the field name 'passwd': {message}");
    assert!(!message.contains("127.0.0.1"), "error message must not contain the request URL/host: {message}");
}

#[tokio::test]
async fn logout_is_idempotent_on_400() {
    let mut server = mockito::Server::new_async().await;
    let _m = server
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::Regex("method=logout".into()))
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
        .mock("POST", "/webapi/entry.cgi")
        .match_body(Matcher::AllOf(vec![
            Matcher::Regex("api=SYNO\\.API\\.Auth".into()),
            Matcher::Regex("method=logout".into()),
            Matcher::Regex("_sid=ABC123".into()),
        ]))
        .with_status(200)
        .with_body(r#"{"success":true,"data":{}}"#)
        .create_async()
        .await;
    let t = transport_for(&server);
    logout(&t, "ABC123").await.expect("logout ok");
}
