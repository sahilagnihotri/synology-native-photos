//! SYNO.Foto.Download / SYNO.FotoTeam.Download, `method=download`.
//!
//! READ-ONLY: this module only fetches the original full-resolution bytes
//! for an asset. It never deletes, edits, or otherwise mutates anything on
//! the NAS.
//!
//! Like `thumbnail.rs`, a successful download answers with the raw file
//! bytes (not a JSON envelope), and only falls back to the usual
//! `{"success":false,"error":{...}}` JSON shape when the request itself
//! fails (bad unit_id, bad cache_key, expired session, ...). Telling the
//! two apart is done purely by `Content-Type`. That dual-mode handling
//! lives once in `envelope::map_binary_or_error` and is reused here rather
//! than duplicated — this was flagged in the pre-flight scan as the dedup
//! point shared with `thumbnail.rs`.
//!
//! PATH DEVIATION FROM THE ORIGINAL TASK BRIEF: the brief's snippet posts to
//! a standalone `/photo/webapi/entry.cgi` path. That is superseded by the
//! verified fact recorded in `documentation/phase0-probe-results.md` and
//! already encoded in `transport.rs`/`thumbnail.rs`: every `SYNO.*` API,
//! including `SYNO.Foto(Team).Download`, is dispatched through the single
//! shared CGI entry point at `/webapi/entry.cgi` (`transport.entry_url()`),
//! not a `/photo/...`-prefixed path. This function follows the verified
//! path, not the brief.
//!
//! UNVERIFIED PARAM-NAME ASSUMPTIONS (no live download probe yet — confirm
//! at first real login): `unit_id` wrapped as a single-element array
//! (`unit_id=[101]`) and `cache_key` as returned by `browse::list_items`,
//! following the brief and community-client precedent (see
//! `documentation/research/2026-07-23-feasibility-research.md`), not a
//! captured real response. Whether `unit_id` is the same value as the
//! asset `id` or a distinct field is also unverified; callers must pass
//! whichever field the real `Browse.Item` response calls `unit_id` once
//! that is confirmed.
//!
//! LARGE FILE NOTE: this returns the full response body as an in-memory
//! `Vec<u8>`. Full-resolution photos and especially videos can be large
//! (tens to hundreds of MB), so this is a real memory-pressure concern for
//! big libraries or 4K video assets. The brief calls for `Vec<u8>` at the
//! core layer for now and defers streaming-to-disk to the Swift side
//! (Task 51 handles temp files there); no chunked/streaming download is
//! implemented here. If large-video downloads prove to be a problem in
//! practice, revisit this signature to stream to a `Write` sink instead of
//! buffering the whole file.

use crate::envelope::map_binary_or_error;
use crate::namespace::download_api;
use crate::transport::Transport;
use models::{CoreError, Space};

/// `SYNO.Foto.Download` / `SYNO.FotoTeam.Download`, `method=download`.
/// Fetches the ORIGINAL full-resolution file bytes for an asset. Space-aware:
/// the API name is resolved via `namespace::download_api`. READ-ONLY: never
/// deletes or mutates anything on the NAS. Writing the returned bytes to a
/// temp file (and cleaning it up) is a Swift-side concern, not this
/// function's — this only fetches.
pub async fn download_original(
    transport: &Transport,
    sid: &str,
    space: Space,
    unit_id: i64,
    cache_key: &str,
    version: u32,
) -> Result<Vec<u8>, CoreError> {
    transport.throttle().await;
    let query: Vec<(&str, String)> = vec![
        ("api", download_api(space).to_string()),
        ("version", version.to_string()),
        ("method", "download".to_string()),
        ("unit_id", format!("[{unit_id}]")),
        ("cache_key", cache_key.to_string()),
        ("_sid", sid.to_string()),
    ];
    let response = transport
        .client()
        .get(transport.entry_url())
        .query(&query)
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("download request failed: {e}") })?;
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let bytes = response
        .bytes()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading download body failed: {e}") })?;
    map_binary_or_error(content_type.as_deref(), &bytes)
}
