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

/// Tolerant decode for a STATE-CHANGING write whose success envelope has no
/// `data` payload we need (album `add_item`/`delete_item`, `Album` delete,
/// `Browse.Item` delete). Unlike `decode_envelope`, this does NOT fail closed
/// on a `success:true` response that omits `data`: those writes legitimately
/// answer with a bare `{"success":true}` (verified against the real NAS), and
/// routing them through `decode_envelope` would misread that success as
/// `UnexpectedResponse`.
///
/// FAIL CLOSED where it still matters:
/// - `success:false` maps `error.code` through `map_error_code` exactly like
///   `decode_envelope`.
/// - A malformed body is `CoreError::Decode`.
/// - If the response DOES carry a `data.error_list` (the `add_item` shape) and
///   that list is non-empty, a per-item write failed even though the top-level
///   envelope claimed success; this returns `CoreError::UnexpectedResponse`
///   rather than reporting a write that did not fully happen. An absent or
///   empty `error_list` is the success case.
pub fn decode_write_success(body: &str) -> Result<(), CoreError> {
    let parsed: WriteResponse = serde_json::from_str(body).map_err(|e| CoreError::Decode {
        message: format!("write envelope parse failed: {e}"),
    })?;
    if !parsed.success {
        let code = parsed.error.map(|e| e.code).unwrap_or(-1);
        return Err(map_error_code(code));
    }
    if let Some(data) = parsed.data {
        if let Some(list) = data.error_list {
            if !list.is_empty() {
                return Err(CoreError::UnexpectedResponse {
                    message: format!("write reported {} per-item error(s) in error_list", list.len()),
                });
            }
        }
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
struct WriteResponse {
    #[serde(default)]
    success: bool,
    #[serde(default = "none")]
    error: Option<SynoError>,
    #[serde(default = "none")]
    data: Option<WriteData>,
}

/// The only field of a write response's `data` this crate inspects: the
/// per-item `error_list` returned by album `add_item`. Everything else in
/// `data` is ignored (tolerant decode, never `deny_unknown_fields`).
#[derive(Debug, Deserialize)]
struct WriteData {
    #[serde(default = "none")]
    error_list: Option<Vec<serde_json::Value>>,
}

/// Shared by every endpoint that answers with raw bytes on success but a
/// JSON error envelope on failure (`SYNO.Foto(Team).Thumbnail`,
/// `SYNO.Foto(Team).Download`, and any future binary-fetch endpoint).
/// Synology signals which mode a response is in purely through
/// `Content-Type`, never through the body shape alone, so the caller is
/// responsible for extracting that header and passing it through here.
///
/// `application/json` in `content_type` => decode `bytes` as a
/// `SynoResponse` and map a failure to `CoreError` via `map_error_code`
/// (a `success:true` JSON body is itself unexpected here — a binary
/// endpoint has no legitimate JSON success shape — so it fails closed into
/// `CoreError::UnexpectedResponse` rather than being treated as image data).
/// Anything else is treated as the binary payload and returned as-is: this
/// fails open on the "is it actually an image" question (we do not sniff
/// magic bytes) but fails closed on the one case Synology actually uses to
/// signal failure, which is what matters for never returning garbage bytes
/// to a caller that will try to decode them as an image.
pub fn map_binary_or_error(content_type: Option<&str>, bytes: &[u8]) -> Result<Vec<u8>, CoreError> {
    // An HTML body from a binary endpoint is always an error page, never
    // image/file bytes. Synology serves one (e.g. a 404 page) when a thumbnail
    // is still being generated (`converting`) or the item is missing; returning
    // those bytes as-is is exactly what produced blank cells and a
    // `CGImageSourceCreateThumbnailAtIndex failed` in the UI. Fail closed here
    // so the caller shows a placeholder and can retry once the NAS finishes,
    // instead of caching an HTML page as if it were an image.
    let is_html = content_type.map(|ct| ct.contains("text/html")).unwrap_or(false);
    if is_html {
        return Err(CoreError::UnexpectedResponse {
            message: "binary endpoint returned an HTML error page instead of image/file bytes (item missing, or its thumbnail is still being generated)".to_string(),
        });
    }
    let is_json = content_type.map(|ct| ct.contains("application/json")).unwrap_or(false);
    if !is_json {
        return Ok(bytes.to_vec());
    }
    let parsed: SynoResponse<serde_json::Value> = serde_json::from_slice(bytes).map_err(|e| CoreError::Decode {
        message: format!("binary error envelope parse failed: {e}"),
    })?;
    if parsed.success {
        return Err(CoreError::UnexpectedResponse {
            message: "binary endpoint returned JSON success instead of image/file bytes".to_string(),
        });
    }
    let code = parsed.error.map(|e| e.code).unwrap_or(-1);
    Err(map_error_code(code))
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

    #[test]
    fn binary_content_type_returns_bytes_as_is() {
        let jpeg_magic = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10];
        let got = map_binary_or_error(Some("image/jpeg"), &jpeg_magic).expect("binary body must pass through");
        assert_eq!(got, jpeg_magic);
    }

    #[test]
    fn missing_content_type_is_treated_as_binary() {
        let bytes = vec![1, 2, 3, 4];
        let got = map_binary_or_error(None, &bytes).expect("no content-type must not be treated as an error");
        assert_eq!(got, bytes);
    }

    #[test]
    fn html_error_page_maps_to_error_not_image_bytes() {
        // A not-yet-generated ("converting") or missing thumbnail comes back as
        // an HTML error page; it must never be returned as if it were an image.
        let body = b"<html><head><title>404</title></head><body>Not Found</body></html>";
        let err = map_binary_or_error(Some("text/html; charset=utf-8"), body).unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn json_error_content_type_maps_to_core_error() {
        let body = br#"{"success":false,"error":{"code":400}}"#;
        let err = map_binary_or_error(Some("application/json"), body).unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[test]
    fn json_content_type_with_unknown_code_fails_closed() {
        let body = br#"{"success":false,"error":{"code":9999}}"#;
        let err = map_binary_or_error(Some("application/json"), body).unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn json_content_type_success_true_fails_closed() {
        // A binary endpoint answering success:true JSON instead of bytes is
        // itself unexpected; it must not be mistaken for image data.
        let body = br#"{"success":true,"data":{}}"#;
        let err = map_binary_or_error(Some("application/json"), body).unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn json_content_type_garbage_body_maps_to_decode() {
        let err = map_binary_or_error(Some("application/json; charset=utf-8"), b"not json").unwrap_err();
        assert!(matches!(err, CoreError::Decode { .. }), "got {err:?}");
    }

    // --- decode_write_success: the write-call decoder --------------------

    #[test]
    fn write_success_bare_success_is_ok() {
        // The Browse.Item / Album delete shape: success with no data field at
        // all. decode_envelope would fail closed here; decode_write_success
        // must accept it.
        decode_write_success(r#"{"success":true}"#).expect("bare success must be Ok");
    }

    #[test]
    fn write_success_empty_error_list_is_ok() {
        // The album add_item shape: success with an empty error_list.
        decode_write_success(r#"{"success":true,"data":{"error_list":[]}}"#).expect("empty error_list must be Ok");
    }

    #[test]
    fn write_success_ignores_unknown_data_fields() {
        decode_write_success(r#"{"success":true,"data":{"album":{"id":7},"future_flag":true}}"#)
            .expect("unknown data fields must not break a write decode");
    }

    #[test]
    fn write_success_non_empty_error_list_fails_closed() {
        // A per-item failure reported under a success envelope must not be
        // treated as a completed write.
        let err = decode_write_success(r#"{"success":true,"data":{"error_list":[{"id":1,"code":123}]}}"#)
            .unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn write_success_false_maps_error_code() {
        let err = decode_write_success(r#"{"success":false,"error":{"code":400}}"#).unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[test]
    fn write_success_false_unknown_code_fails_closed() {
        let err = decode_write_success(r#"{"success":false,"error":{"code":9999}}"#).unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn write_success_garbage_body_maps_to_decode() {
        let err = decode_write_success("not json at all").unwrap_err();
        assert!(matches!(err, CoreError::Decode { .. }), "got {err:?}");
    }
}
