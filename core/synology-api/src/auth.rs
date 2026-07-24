//! SYNO.API.Auth: login (with optional 2FA/OTP and device-trust) and logout.
//!
//! Every DSM API, including auth, is dispatched through the single CGI
//! entry point at `/webapi/entry.cgi` (verified against the real NAS, see
//! `documentation/phase0-probe-results.md`); there is no separate
//! `/photo/webapi/auth.cgi`.
//!
//! SECURITY: `login` sends every parameter (account, password, OTP code,
//! device token) in the POST FORM BODY via `Transport::post_form`, never as
//! a URL query string. This matters for two independent reasons: a query
//! string ends up in server/proxy access logs and in `reqwest::Error`'s
//! `Display` output on failure, either of which would otherwise leak the
//! password verbatim (this happened in an earlier version of this client
//! and is the reason this module exists in its current shape). Every error
//! path in this module is built from `Transport`'s scrubbed error mapping
//! (`without_url`, no body echo) or from `envelope::decode_envelope`, neither
//! of which ever includes request parameters; see the
//! `login_error_never_contains_password_or_field_name` test in
//! `tests/auth_mock.rs`.
//!
//! The account this app authenticates as has 2FA enabled, so the OTP path
//! is exercised on every real login, not just as an edge case. When DSM
//! requires a one-time code and none was supplied (and no trusted device
//! token was sent either), it answers with an error envelope (mapped by
//! `envelope::map_error_code` to `CoreError::OtpRequired`); the caller (UI
//! layer) is expected to prompt the user and retry `login` with
//! `otp_code = Some(code)`.
//!
//! ## Device-token 2FA ("trust this device")
//!
//! DSM's `SYNO.API.Auth` supports remembering a device across logins so OTP
//! is only required once per device. This module implements that as follows,
//! per the task brief's UNVERIFIED-pending-real-NAS-confirmation note:
//! - On a login that supplies `otp_code`, we also send `enable_device_token`
//!   `= "yes"` and a `device_name`. If DSM accepts the login it may return a
//!   device token in the response; we decode it tolerantly under either of
//!   the two commonly-documented field names, `did` and `device_id` (`did`
//!   preferred if both are present).
//! - The returned token is surfaced on `Session.device_did` exactly like any
//!   other login: callers (the core/UI layer) are responsible for persisting
//!   it (Keychain, keyed by host+account) and passing it back in as
//!   `device_token` on a later `login` call.
//! - When `device_token` is `Some`, we send it under BOTH candidate param
//!   names (`did` and `device_id`) so whichever one this DSM actually reads
//!   is honored, without needing to guess incorrectly and silently fail
//!   closed into an OTP prompt every time.
//! - Sending a device token is always *in addition to* whatever `otp_code`
//!   was given, never a replacement for the OTP-required error path: if DSM
//!   rejects the device token (expired, revoked, wrong account) it answers
//!   exactly like any other missing-2FA login, which decodes to
//!   `CoreError::OtpRequired` here. That is fail-closed by construction: a
//!   bad/stale device token can only ever fall back to asking for a fresh
//!   OTP, it can never itself grant a session.
//!
//! Response field names for the login payload (`sid`, `synotoken`, `did`/
//! `device_id`) follow the naming used by Synology's official API
//! documentation and widely-used community clients, but have NOT yet been
//! confirmed against this user's real NAS (the live login probe was
//! deferred). They are decoded tolerantly: `sid` is the only field we treat
//! as required. Validate this assumption at the user's first real login and
//! adjust the field names here if DSM 7.x on this NAS uses different
//! casing/keys.

use crate::transport::Transport;
use models::{CoreError, Session};
use serde::Deserialize;

const AUTH_API: &str = "SYNO.API.Auth";
const AUTH_VERSION: &str = "3";

/// Device name sent alongside `enable_device_token=yes`. DSM's device list
/// (Control Panel > Account > ...) shows this to the user, so it should be
/// stable and recognizable rather than a random string.
const DEVICE_NAME: &str = "synology-native-photos-mac";

#[derive(Debug, Deserialize)]
struct LoginData {
    sid: String,
    #[serde(default)]
    synotoken: Option<String>,
    #[serde(default)]
    did: Option<String>,
    #[serde(default)]
    device_id: Option<String>,
}

impl LoginData {
    /// `did` is the primary, commonly-documented field name; `device_id` is
    /// the fallback for a DSM build that uses the other name instead. See
    /// the module-level doc comment for why both are decoded.
    fn device_token(&self) -> Option<String> {
        self.did.clone().or_else(|| self.device_id.clone())
    }
}

/// Log in via `SYNO.API.Auth` `method=login`.
///
/// All parameters (`account`, `passwd`, `otp_code`, device-trust params) are
/// sent in the POST form body via `Transport::post_form`, never in a URL
/// query string; see the module-level doc comment for why that matters.
///
/// - `otp_code` is included only when `Some`; DSM rejects an empty
///   `otp_code` param the same as if the user's account did not have 2FA
///   enabled, so we never send the key at all when no code was given.
/// - `device_token` is a previously-stored device token from an earlier
///   login's `Session.device_did` (see the module doc comment on
///   device-token 2FA). When `Some`, it is sent under both `did` and
///   `device_id` so it is honored regardless of which name this DSM build
///   expects, letting a trusted device skip OTP entirely.
/// - Whenever `otp_code` is supplied, `enable_device_token=yes` and a fixed
///   `device_name` are also sent so DSM can mint a new device token for this
///   login, which is then returned via `Session.device_did` for the caller
///   to persist.
///
/// On success returns a `Session` with `sid` always populated, `syno_token`
/// populated when DSM includes it (requires `enable_syno_token=yes`, always
/// sent), and `device_did` populated whenever DSM's response includes a
/// device token (freshly minted from this login, or otherwise).
///
/// Error mapping (via `envelope::decode_envelope` / `map_error_code`):
/// - DSM error code 403 (or 404) with no OTP/device-token accepted means DSM
///   wants a one-time code: surfaces as `CoreError::OtpRequired` so the UI
///   can prompt and retry. This is also what happens if a stored
///   `device_token` is stale/expired/revoked: DSM answers exactly as if no
///   2FA had been supplied at all, so a bad device token fails closed into
///   the same OTP prompt rather than ever granting a session on its own.
/// - DSM error code 400/401 (bad credentials, or a wrong/expired OTP)
///   surfaces as `CoreError::Auth`.
/// - Anything else fails closed into `CoreError::UnexpectedResponse` or
///   `CoreError::Decode`.
pub async fn login(
    transport: &Transport,
    username: &str,
    password: &str,
    otp_code: Option<&str>,
    device_token: Option<&str>,
) -> Result<Session, CoreError> {
    let mut form: Vec<(&str, &str)> = vec![
        ("api", AUTH_API),
        ("version", AUTH_VERSION),
        ("method", "login"),
        ("account", username),
        ("passwd", password),
        ("format", "sid"),
        ("enable_syno_token", "yes"),
    ];
    if let Some(code) = otp_code {
        form.push(("otp_code", code));
        form.push(("enable_device_token", "yes"));
        form.push(("device_name", DEVICE_NAME));
    }
    if let Some(token) = device_token {
        // Sent under both commonly-documented names; see module doc comment.
        form.push(("did", token));
        form.push(("device_id", token));
    }

    let data: LoginData = transport.post_form(&form).await?;
    Ok(Session {
        sid: data.sid.clone(),
        syno_token: data.synotoken.clone(),
        username: username.to_string(),
        device_did: data.device_token(),
    })
}

/// Log out via `SYNO.API.Auth` `method=logout`.
///
/// Idempotent: if the session is already gone, DSM answers with an error
/// envelope that `decode_envelope` maps to `CoreError::Auth` or
/// `CoreError::UnexpectedResponse`; both are treated as "already logged
/// out" rather than propagated, so callers can call `logout` freely
/// during cleanup/error paths without checking session validity first.
///
/// Uses the POST form body (via `Transport::post_form`), same as `login`,
/// even though `_sid` alone is not secret to the same degree a password is:
/// keeping every `SYNO.API.Auth` call on one consistent transport path
/// avoids a future edit accidentally reintroducing a query-string call here.
pub async fn logout(transport: &Transport, sid: &str) -> Result<(), CoreError> {
    let form: Vec<(&str, &str)> = vec![
        ("api", AUTH_API),
        ("version", AUTH_VERSION),
        ("method", "logout"),
        ("_sid", sid),
    ];

    match transport.post_form::<serde_json::Value>(&form).await {
        Ok(_) => Ok(()),
        Err(CoreError::Auth { .. }) => Ok(()),
        Err(CoreError::UnexpectedResponse { .. }) => Ok(()),
        Err(other) => Err(other),
    }
}
