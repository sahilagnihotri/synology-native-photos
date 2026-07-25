//! SYNO.FileStation.Upload, `method=upload`.
//!
//! ADD-ONLY: this module only ever WRITES A NEW FILE into a folder. It never
//! deletes, overwrites, or otherwise mutates an existing file. The edited-photo
//! save flow (see `photoscore::save_edited_photo`) uses it to land the edited
//! copy as a brand-new asset alongside the untouched original, upholding the
//! project's non-destructive-edit invariant: the original NAS file is never
//! written to. `overwrite` is pinned to `false` here so the call fails closed
//! rather than clobbering a file if a name ever collides.
//!
//! CRITICAL request-shape facts, VERIFIED live against the real NAS (recorded
//! in the feature brief's reconnaissance) and easy to get wrong:
//!
//! - The SynoToken (CSRF token) MUST travel in the URL QUERY STRING
//!   (`?SynoToken=...`), not only as the `X-SYNO-TOKEN` header. With the header
//!   alone DSM answers a token-auth session with error 119, exactly like the
//!   read/state-change calls elsewhere in this crate, but for Upload the header
//!   is not enough on its own. We send BOTH (query + header); the query is the
//!   part DSM actually honors for this endpoint.
//! - The file part MUST be the LAST part in the multipart body. DSM parses the
//!   preceding text fields (api/version/method/path/create_parents/overwrite)
//!   as the upload parameters and treats the first file part it sees as the
//!   payload; placing the file last guarantees every parameter is in hand
//!   before the bytes arrive. `reqwest::multipart::Form` preserves insertion
//!   order, so adding the file part last is what puts it last on the wire.
//! - `create_parents=true` so the destination folder (e.g. a dedicated
//!   `.../Edited` directory) is created on demand rather than the upload
//!   failing because the folder does not exist yet.
//!
//! `Transport::post_form`/`post_form_text` only speak
//! `application/x-www-form-urlencoded`, so this builds the multipart request
//! directly off the public `transport.client()` + `transport.entry_url()`, the
//! same escape hatch `download.rs`/`thumbnail.rs` use for their raw requests.
//! The bare-`{"success":true}` response is decoded through
//! `decode_write_success` (tolerant of a missing/extra `data`, still fails
//! closed on `success:false`).

use crate::envelope::decode_write_success;
use crate::transport::Transport;
use models::CoreError;

/// Uploads `bytes` as a NEW file named `filename` into `dest_folder_path` via
/// `SYNO.FileStation.Upload` (`method=upload`). ADD-ONLY: `overwrite=false` and
/// `create_parents=true`, so this never clobbers an existing file and creates
/// the destination folder on demand.
///
/// `syno_token` is `Session.syno_token` from login; it is sent BOTH as the
/// `SynoToken` query parameter (which DSM honors for this endpoint) and as the
/// `X-SYNO-TOKEN` header. Pass `None` to omit both (DSM will then reject a
/// token-auth session with error 119, surfaced as a `CoreError`).
///
/// Fails closed on any non-success envelope (`decode_write_success`).
pub async fn upload_file(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
    dest_folder_path: &str,
    filename: &str,
    bytes: &[u8],
) -> Result<(), CoreError> {
    transport.throttle().await;

    // The file part is added LAST so it is last on the wire (see module doc);
    // reqwest's multipart Form preserves insertion order.
    let file_part = reqwest::multipart::Part::bytes(bytes.to_vec())
        .file_name(filename.to_string())
        .mime_str("application/octet-stream")
        .map_err(|e| CoreError::Network { message: format!("could not build upload file part: {e}") })?;
    let form = reqwest::multipart::Form::new()
        .text("api", "SYNO.FileStation.Upload")
        .text("version", "2")
        .text("method", "upload")
        .text("path", dest_folder_path.to_string())
        .text("create_parents", "true")
        .text("overwrite", "false")
        .part("file", file_part);

    // Auth in the query string: `_sid` plus the SynoToken DSM requires here.
    let mut query: Vec<(&str, &str)> = vec![("_sid", sid)];
    if let Some(token) = syno_token {
        query.push(("SynoToken", token));
    }

    let mut request = transport.client().post(transport.entry_url()).query(&query).multipart(form);
    if let Some(token) = syno_token {
        request = request.header("X-SYNO-TOKEN", token);
    }

    let response = request
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("upload request failed: {e}") })?;
    let body = response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading upload response body failed: {e}") })?;
    decode_write_success(&body)
}

#[cfg(test)]
mod tests {
    use super::*;
    use models::Connection;

    fn conn(host: &str) -> Connection {
        Connection { host: host.to_string(), verify_tls: true, pinned_cert_der: None, allow_untrusted_tls: false }
    }

    #[tokio::test]
    async fn upload_sends_synotoken_in_query_and_overwrite_false_with_file_last() {
        let mut server = mockito::Server::new_async().await;
        let mock = server
            .mock("POST", "/webapi/entry.cgi")
            // SynoToken MUST be in the query string (not only the header).
            .match_query(mockito::Matcher::AllOf(vec![
                mockito::Matcher::UrlEncoded("SynoToken".into(), "TK".into()),
                mockito::Matcher::UrlEncoded("_sid".into(), "SID".into()),
            ]))
            .match_body(mockito::Matcher::AllOf(vec![
                mockito::Matcher::Regex(r#"name="api"[\s\S]*SYNO.FileStation.Upload"#.into()),
                mockito::Matcher::Regex(r#"name="overwrite"\r\n\r\nfalse"#.into()),
                mockito::Matcher::Regex(r#"name="create_parents"\r\n\r\ntrue"#.into()),
                // The file part carries the filename and comes AFTER the
                // overwrite text field: file part is last.
                mockito::Matcher::Regex(r#"name="overwrite"[\s\S]*filename="edited.jpg""#.into()),
            ]))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"success":true}"#)
            .create_async()
            .await;

        let transport = Transport::new(&conn(&server.url())).expect("transport builds");
        upload_file(&transport, "SID", Some("TK"), "/home/Photos/Edited", "edited.jpg", b"FAKEJPEGBYTES")
            .await
            .expect("upload should succeed");
        mock.assert_async().await;
    }

    #[tokio::test]
    async fn upload_maps_error_envelope_to_core_error() {
        let mut server = mockito::Server::new_async().await;
        server
            .mock("POST", "/webapi/entry.cgi")
            // The auth params ride in the query string; without a query matcher
            // mockito's default rejects any request that carries one.
            .match_query(mockito::Matcher::Any)
            .match_body(mockito::Matcher::Regex("SYNO.FileStation.Upload".into()))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"success":false,"error":{"code":400}}"#)
            .create_async()
            .await;

        let transport = Transport::new(&conn(&server.url())).expect("transport builds");
        let err = upload_file(&transport, "SID", Some("TK"), "/home/Photos/Edited", "edited.jpg", b"x")
            .await
            .unwrap_err();
        assert!(matches!(err, CoreError::Auth { .. }), "got {err:?}");
    }

    #[tokio::test]
    async fn upload_without_token_omits_synotoken_query() {
        let mut server = mockito::Server::new_async().await;
        // No SynoToken query param is present when the token is None.
        let mock = server
            .mock("POST", "/webapi/entry.cgi")
            .match_query(mockito::Matcher::Any)
            .match_request(|req| !req.path_and_query().contains("SynoToken"))
            .with_status(200)
            .with_header("content-type", "application/json")
            .with_body(r#"{"success":true}"#)
            .create_async()
            .await;

        let transport = Transport::new(&conn(&server.url())).expect("transport builds");
        upload_file(&transport, "SID", None, "/home/Photos/Edited", "edited.jpg", b"x")
            .await
            .expect("upload should succeed without a token");
        mock.assert_async().await;
    }
}
