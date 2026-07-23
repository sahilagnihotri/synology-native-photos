//! SYNO.API.Auth: login (with optional 2FA/OTP) and logout.
//!
//! Every DSM API, including auth, is dispatched through the single CGI
//! entry point at `/webapi/entry.cgi` (verified against the real NAS, see
//! `documentation/phase0-probe-results.md`); there is no separate
//! `/photo/webapi/auth.cgi`. Requests are sent as GET with query params,
//! matching the shape Synology's own API browser and community clients use
//! for `SYNO.API.Auth`.
//!
//! The account this app authenticates as has 2FA enabled, so the OTP path
//! is exercised on every real login, not just as an edge case. When DSM
//! requires a one-time code and none was supplied, it answers with an
//! error envelope (mapped by `envelope::map_error_code` to
//! `CoreError::OtpRequired`); the caller (UI layer) is expected to prompt
//! the user and retry `login` with `otp_code = Some(code)`.
//!
//! Response field names for the login payload (`sid`, `synotoken`, `did`)
//! follow the naming used by Synology's official API documentation and
//! widely-used community clients, but have NOT yet been confirmed against
//! this user's real NAS (the live login probe was deferred). They are
//! decoded tolerantly: `sid` is the only field we treat as required, and
//! `synotoken`/`did` default to `None` if absent or differently named.
//! Validate this assumption at the user's first real login and adjust the
//! field names here if DSM 7.x on this NAS uses different casing/keys.

use crate::envelope::decode_envelope;
use crate::transport::Transport;
use models::{CoreError, Session};
use serde::Deserialize;

const AUTH_API: &str = "SYNO.API.Auth";
const AUTH_VERSION: &str = "3";

#[derive(Debug, Deserialize)]
struct LoginData {
    sid: String,
    #[serde(default)]
    synotoken: Option<String>,
    #[serde(default)]
    did: Option<String>,
}

/// Log in via `SYNO.API.Auth` `method=login`.
///
/// `otp_code` is included in the request only when `Some`; DSM rejects an
/// empty `otp_code` param the same as if the user's account did not have
/// 2FA enabled, so we never send the key at all when no code was given.
///
/// On success returns a `Session` with `sid` always populated and
/// `syno_token`/`device_did` populated when DSM includes them (requires
/// `enable_syno_token=yes`, which is always sent).
///
/// Error mapping (via `envelope::decode_envelope` / `map_error_code`):
/// - DSM error code 403 (or 404) with no `otp_code` supplied means DSM
///   wants a one-time code: surfaces as `CoreError::OtpRequired` so the UI
///   can prompt and retry.
/// - DSM error code 400/401 (bad credentials, or a wrong/expired OTP)
///   surfaces as `CoreError::Auth`.
/// - Anything else fails closed into `CoreError::UnexpectedResponse` or
///   `CoreError::Decode`.
pub async fn login(
    transport: &Transport,
    username: &str,
    password: &str,
    otp_code: Option<&str>,
) -> Result<Session, CoreError> {
    transport.throttle().await;

    let mut query: Vec<(&str, &str)> = vec![
        ("api", AUTH_API),
        ("version", AUTH_VERSION),
        ("method", "login"),
        ("account", username),
        ("passwd", password),
        ("format", "sid"),
        ("enable_syno_token", "yes"),
    ];
    if let Some(code) = otp_code {
        query.push(("otp_code", code));
    }

    let response = transport
        .client()
        .get(transport.entry_url())
        .query(&query)
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("login request failed: {e}") })?;
    let body = response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("failed to read login response body: {e}") })?;

    let data: LoginData = decode_envelope(&body)?;
    Ok(Session {
        sid: data.sid,
        syno_token: data.synotoken,
        username: username.to_string(),
        device_did: data.did,
    })
}

/// Log out via `SYNO.API.Auth` `method=logout`.
///
/// Idempotent: if the session is already gone, DSM answers with an error
/// envelope that `decode_envelope` maps to `CoreError::Auth` or
/// `CoreError::UnexpectedResponse`; both are treated as "already logged
/// out" rather than propagated, so callers can call `logout` freely
/// during cleanup/error paths without checking session validity first.
pub async fn logout(transport: &Transport, sid: &str) -> Result<(), CoreError> {
    transport.throttle().await;

    let query: Vec<(&str, &str)> = vec![
        ("api", AUTH_API),
        ("version", AUTH_VERSION),
        ("method", "logout"),
        ("_sid", sid),
    ];

    let response = transport
        .client()
        .get(transport.entry_url())
        .query(&query)
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("logout request failed: {e}") })?;
    let body = response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("failed to read logout response body: {e}") })?;

    match decode_envelope::<serde_json::Value>(&body) {
        Ok(_) => Ok(()),
        Err(CoreError::Auth { .. }) => Ok(()),
        Err(CoreError::UnexpectedResponse { .. }) => Ok(()),
        Err(other) => Err(other),
    }
}
