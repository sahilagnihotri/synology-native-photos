//! SYNO.Foto.Thumbnail / SYNO.FotoTeam.Thumbnail, `method=get`.
//!
//! Unlike every other endpoint in this crate, a successful thumbnail fetch
//! answers with the raw image bytes, not a JSON envelope. Synology only
//! falls back to the usual `{"success":false,"error":{...}}` JSON shape
//! when the request itself fails (bad id, bad cache_key, expired session,
//! ...). Telling the two apart is done purely by `Content-Type` (see
//! `envelope::map_binary_or_error`, which owns that logic so
//! `download::download_original` can reuse it rather than duplicating this
//! dual-mode handling).
//!
//! Like every other API in this crate, the request is dispatched through
//! the shared CGI entry point at `/webapi/entry.cgi` (verified against the
//! real NAS, see `documentation/phase0-probe-results.md`), reached here via
//! `transport.entry_url()` — not a separate `/photo/webapi/entry.cgi` path.
//! `SYNO.Foto.Thumbnail`'s advertised version window tops out at 2 on the
//! real NAS (lower than the browse APIs at 7); callers are expected to pin
//! `version` with `info::pin_version` against a live capability probe
//! rather than hardcoding it here.
//!
//! UNVERIFIED PARAM-NAME ASSUMPTIONS (no live thumbnail probe yet — confirm
//! at first real login): the query parameters below (`id` for the asset id,
//! `cache_key` as returned by `browse::list_items`, `type=unit` for a
//! single-item fetch, and `size` taking `sm`/`m`/`xl`) follow the brief and
//! community-client precedent, not a captured real response.

use crate::envelope::map_binary_or_error;
use crate::namespace::thumbnail_api;
use crate::transport::Transport;
use models::{CoreError, Space, ThumbnailSize};

/// Map a `ThumbnailSize` to the query value Synology expects.
pub fn size_param(size: ThumbnailSize) -> &'static str {
    match size {
        ThumbnailSize::Sm => "sm",
        ThumbnailSize::M => "m",
        ThumbnailSize::Xl => "xl",
    }
}

/// `SYNO.Foto.Thumbnail` / `SYNO.FotoTeam.Thumbnail`, `method=get`. Returns
/// the raw image bytes on success. Space-aware: the API name is resolved
/// via `namespace::thumbnail_api`. On-disk caching of the returned bytes is
/// a Swift-side concern, not this crate's — this function only fetches.
pub async fn fetch_thumbnail(
    transport: &Transport,
    sid: &str,
    space: Space,
    asset_id: i64,
    cache_key: &str,
    size: ThumbnailSize,
    version: u32,
) -> Result<Vec<u8>, CoreError> {
    transport.throttle().await;
    let query: Vec<(&str, String)> = vec![
        ("api", thumbnail_api(space).to_string()),
        ("version", version.to_string()),
        ("method", "get".to_string()),
        ("id", asset_id.to_string()),
        ("cache_key", cache_key.to_string()),
        ("type", "unit".to_string()),
        ("size", size_param(size).to_string()),
        ("_sid", sid.to_string()),
    ];
    let response = transport
        .client()
        .get(transport.entry_url())
        .query(&query)
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("thumbnail request failed: {e}") })?;
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let bytes = response
        .bytes()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading thumbnail body failed: {e}") })?;
    map_binary_or_error(content_type.as_deref(), &bytes)
}
