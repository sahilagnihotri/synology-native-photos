//! Tolerant decode for the Synology Web API response envelope.
//!
//! Every Synology endpoint responds with the same wrapper shape:
//! `{"success": bool, "data": {...}, "error": {"code": N}}`. Because the
//! API is unofficial and undocumented, the wrapper (and the payloads
//! inside `data`) can gain fields across DSM releases without warning.
//! This module never uses `deny_unknown_fields`: unknown/extra fields
//! anywhere in the JSON are ignored rather than treated as a parse
//! failure. Anything we cannot positively recognize (an error code we
//! don't have a mapping for, a `success:true` envelope missing `data`)
//! fails closed into `CoreError::UnexpectedResponse` instead of being
//! treated as success.

use models::CoreError;
use serde::de::DeserializeOwned;
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct SynoResponse<T> {
    #[serde(default)]
    pub success: bool,
    #[serde(default = "none")]
    pub data: Option<T>,
    #[serde(default = "none")]
    pub error: Option<SynoError>,
}

fn none<T>() -> Option<T> {
    None
}

#[derive(Debug, Deserialize)]
pub struct SynoError {
    pub code: i64,
}

/// Map a Synology error.code to a CoreError per the authoritative contract.
/// FAIL CLOSED: any code we do not explicitly recognize becomes UnexpectedResponse.
pub fn map_error_code(code: i64) -> CoreError {
    match code {
        400 | 401 => CoreError::Auth {
            message: format!("synology auth error code {code}"),
        },
        403 | 404 => CoreError::OtpRequired,
        other => CoreError::UnexpectedResponse {
            message: format!("unhandled synology error code {other}"),
        },
    }
}

/// Tolerant decode: unknown fields inside T are ignored (we never use
/// deny_unknown_fields). success:false => mapped error. Missing data on
/// success:true => fail closed. Serde failure => Decode.
pub fn decode_envelope<T: DeserializeOwned>(body: &str) -> Result<T, CoreError> {
    let parsed: SynoResponse<T> = serde_json::from_str(body).map_err(|e| CoreError::Decode {
        message: format!("envelope parse failed: {e}"),
    })?;
    if parsed.success {
        parsed.data.ok_or_else(|| CoreError::UnexpectedResponse {
            message: "success=true but data field missing".to_string(),
        })
    } else {
        let code = parsed.error.map(|e| e.code).unwrap_or(-1);
        Err(map_error_code(code))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::CoreError;
    use serde::Deserialize;

    #[derive(Debug, Deserialize, PartialEq)]
    struct Known {
        id: i64,
        name: String,
    }

    #[test]
    fn decodes_success_ignoring_unknown_fields() {
        let body = r#"{ "success": true, "data": { "id": 7, "name": "beach", "extra_meta": {"x": 1}, "future_flag": true } }"#;
        let got: Known = decode_envelope(body).expect("unknown fields must not break decode");
        assert_eq!(
            got,
            Known {
                id: 7,
                name: "beach".into()
            }
        );
    }

    #[test]
    fn success_false_400_maps_to_auth() {
        let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 400 } }"#)
            .unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[test]
    fn success_false_403_maps_to_otp_required() {
        let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 403 } }"#)
            .unwrap_err();
        assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");
    }

    #[test]
    fn success_false_404_maps_to_otp_required() {
        let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 404 } }"#)
            .unwrap_err();
        assert!(matches!(err, CoreError::OtpRequired), "got {err:?}");
    }

    #[test]
    fn success_false_unknown_code_fails_closed_unexpected() {
        let err = decode_envelope::<Known>(r#"{ "success": false, "error": { "code": 9999 } }"#)
            .unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn garbage_body_maps_to_decode() {
        let err = decode_envelope::<Known>("not json at all").unwrap_err();
        assert!(matches!(err, CoreError::Decode { .. }), "got {err:?}");
    }

    #[test]
    fn success_true_missing_data_fails_closed() {
        let err = decode_envelope::<Known>(r#"{ "success": true }"#).unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }
}
