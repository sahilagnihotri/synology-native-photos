//! SYNO.Foto.Browse.Item / SYNO.Foto.Browse.Album (and their `FotoTeam`
//! counterparts): space-aware paginated listing of assets and albums.
//!
//! Like every other API in this crate, both calls are dispatched through
//! the shared CGI entry point at `/webapi/entry.cgi` (verified against the
//! real NAS, see `documentation/phase0-probe-results.md`), reached here via
//! `transport.entry_url()` — not a separate `/photo/webapi/entry.cgi` path.
//! Which `SYNO.*` API name to send (`SYNO.Foto.Browse.Item` vs
//! `SYNO.FotoTeam.Browse.Item`, and the `.Album` equivalents) comes from the
//! `namespace` module's space resolver rather than being hardcoded, so
//! calling with `Space::Shared` automatically targets the FotoTeam surface.
//!
//! Item and album payloads are decoded tolerantly: real Synology objects
//! carry many fields this crate does not model (and DSM can add more across
//! releases), so unknown fields are ignored rather than treated as a parse
//! failure — this module never uses `deny_unknown_fields`. An item's `type`
//! is matched against the media kinds we recognize; anything else
//! (including a value we've simply never seen, e.g. a future
//! `"live_photo"`) decodes as `MediaKind::Unknown` rather than failing the
//! whole list.
//!
//! Decoding is also tolerant *per element*, not just per field: `list` is
//! parsed as `Vec<serde_json::Value>` first, then each element is decoded
//! into `RawItem`/`RawAlbum` independently. Because a real NAS response can
//! contain one malformed item (a missing/renamed field is exactly the kind
//! of thing we can't fully rule out — see the UNVERIFIED note below), a
//! naive `Vec<RawItem>` field would fail serde for the *entire* batch the
//! moment a single element doesn't match, breaking all browsing rather than
//! just that one item. Instead, each element that fails to decode, or
//! decodes but lacks the minimum viable identity (an item needs `id` *and*
//! `cache_key`; an album needs `id`), is skipped and logged via
//! `tracing::warn!` with a count and reason; items/albums missing only
//! optional fields (`filename`, `time`, `name`, ...) still produce a usable
//! value with a sensible default rather than being dropped.
//!
//! UNVERIFIED FIELD-NAME ASSUMPTIONS (no live browse probe yet — see the
//! task report for the full list to confirm at first real login): item
//! `time` (taken-at epoch seconds), `filesize`, and the nesting of
//! `cache_key` under `additional.thumbnail` and `width`/`height` under
//! `additional.resolution` all follow the brief and community-client
//! precedent, not a captured real response. `filename` and `id` are the
//! most likely to be correct as-is since they match Synology's officially
//! documented File Station conventions, but should still be checked.

use crate::envelope::decode_envelope;
use crate::namespace::{browse_album_api, browse_item_api};
use crate::transport::Transport;
use models::{Album, Asset, CoreError, MediaKind, Space};
use serde::Deserialize;

/// Map the item's `type` string to a `MediaKind`. Anything unrecognized
/// (including future Synology media types we've never seen) falls back to
/// `MediaKind::Unknown` rather than failing the decode — fail closed on the
/// *meaning* of the type, not on the ability to list the item at all.
fn parse_media_kind(raw: &str) -> MediaKind {
    match raw {
        "photo" => MediaKind::Photo,
        "video" => MediaKind::Video,
        _ => MediaKind::Unknown,
    }
}

#[derive(Debug, Deserialize)]
struct ItemList {
    // Deserialized as raw JSON values, not `Vec<RawItem>` directly: see the
    // module doc-comment. Each element is decoded into `RawItem`
    // independently in `list_items` so one malformed element can be skipped
    // and logged instead of failing the whole batch.
    #[serde(default)]
    list: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct RawItem {
    id: i64,
    // ASSUMPTION (unverified): most likely-correct field name (matches
    // File Station convention), but still not exercised against a real
    // response, so it defaults rather than hard-failing decode when absent
    // or renamed. A missing filename does not make an item unusable — the
    // caller can still fetch/display it by `id`/`cache_key` — so this
    // module falls back to the id itself rather than dropping the item.
    #[serde(default)]
    filename: Option<String>,
    #[serde(rename = "type", default)]
    kind: String,
    // ASSUMPTION (unverified against real NAS): taken-at epoch seconds is
    // reported under `time`. Community clients and the brief agree on this
    // name; confirm at first real login.
    #[serde(default)]
    time: Option<i64>,
    // ASSUMPTION (unverified): added-to-library timestamp under
    // `create_time`. Not exercised by the mock fixtures either; kept
    // optional so its absence never breaks decode.
    #[serde(default)]
    create_time: Option<i64>,
    // ASSUMPTION (unverified): file size in bytes under `filesize`.
    #[serde(default)]
    filesize: Option<u64>,
    #[serde(default)]
    version: Option<i64>,
    #[serde(default)]
    additional: Option<ItemAdditional>,
}

#[derive(Debug, Deserialize, Default)]
struct ItemAdditional {
    #[serde(default)]
    thumbnail: Option<Thumb>,
    #[serde(default)]
    resolution: Option<Resolution>,
}

#[derive(Debug, Deserialize)]
struct Thumb {
    // ASSUMPTION (unverified): the thumbnail cache key needed for later
    // thumbnail/download calls is nested at `additional.thumbnail.cache_key`.
    #[serde(default)]
    cache_key: String,
}

#[derive(Debug, Deserialize)]
struct Resolution {
    // ASSUMPTION (unverified): pixel dimensions nested at
    // `additional.resolution.{width,height}`.
    #[serde(default)]
    width: Option<u32>,
    #[serde(default)]
    height: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct AlbumList {
    // Raw values, decoded per-element into `RawAlbum` in `list_albums` for
    // the same reason as `ItemList::list` above: one malformed album must
    // not fail the rest of the page.
    #[serde(default)]
    list: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct RawAlbum {
    id: i64,
    // ASSUMPTION (unverified): optional so a missing/renamed `name` still
    // yields a usable album (falls back to the id) rather than being
    // dropped from the list.
    #[serde(default)]
    name: Option<String>,
    // ASSUMPTION (unverified): album size is reported as `item_count`.
    #[serde(default)]
    item_count: u32,
    #[serde(default)]
    additional: Option<ItemAdditional>,
}

/// Decode a single raw list element into `T`, logging and returning `None`
/// on failure instead of propagating the error. Shared by `list_items` and
/// `list_albums` so a lone malformed element (missing/renamed field, wrong
/// type, ...) never fails the rest of the page — only that one element is
/// dropped. `kind` and `raw_id` are for the log message only (`raw_id` is
/// best-effort: a malformed element may not even have a readable `id`).
fn decode_one<T: serde::de::DeserializeOwned>(
    value: &serde_json::Value,
    kind: &str,
) -> Option<T> {
    match serde_json::from_value::<T>(value.clone()) {
        Ok(parsed) => Some(parsed),
        Err(e) => {
            let raw_id = value.get("id").map(|v| v.to_string()).unwrap_or_else(|| "?".to_string());
            tracing::warn!(
                "skipping malformed {kind} (id={raw_id}): failed to decode: {e}"
            );
            None
        }
    }
}

/// Issue a GET against the shared entry.cgi dispatcher and return the raw
/// response body for `decode_envelope` to parse. Shared by `list_items` and
/// `list_albums` so both go through the same throttle/error-mapping path.
///
/// Sends `X-SYNO-TOKEN: <token>` when `syno_token` is `Some` (DSM's CSRF
/// token check on top of `_sid`; without it a session with token auth
/// active answers `_sid`-bearing calls with synology error 119). The header
/// is omitted entirely when `syno_token` is `None`, never sent empty.
async fn get_body(
    transport: &Transport,
    query: &[(&str, String)],
    syno_token: Option<&str>,
) -> Result<String, CoreError> {
    transport.throttle().await;
    let query_refs: Vec<(&str, &str)> = query.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let mut request = transport.client().get(transport.entry_url()).query(&query_refs);
    if let Some(token) = syno_token {
        request = request.header("X-SYNO-TOKEN", token);
    }
    let response = request
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("browse request failed: {e}") })?;
    response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading browse response body failed: {e}") })
}

/// `SYNO.Foto.Browse.Item` / `SYNO.FotoTeam.Browse.Item`, `method=list`.
/// Space-aware: the API name is resolved from `space` via `namespace`, and
/// every returned `Asset.space` is set to the same `space` the caller asked
/// for (the item payload itself carries no space marker). Requests
/// `additional=["thumbnail","resolution"]` so each item comes back with a
/// `cache_key` (needed for thumbnails/downloads) and pixel dimensions.
/// Unknown item fields are ignored; an unrecognized `type` decodes as
/// `MediaKind::Unknown` rather than failing the whole list.
///
/// Decoding is per-element and tolerant: an element that fails to
/// deserialize into `RawItem` at all, or one that decodes but is missing
/// `id` or a non-empty `cache_key` (the minimum viable `Asset` — `cache_key`
/// is required to fetch thumbnails/originals later), is skipped rather than
/// failing the whole page. Skipped elements are logged via `tracing::warn!`
/// with a total count so a bad batch is visible without breaking browsing.
/// An item missing only optional fields (`filename`, `time`, `filesize`,
/// dimensions, ...) still produces a usable `Asset` with defaults.
///
/// `syno_token` is `Session.syno_token` from login, forwarded as the
/// `X-SYNO-TOKEN` header (see `get_body`); pass `None` when the session has
/// no token, in which case the header is simply omitted.
pub async fn list_items(
    transport: &Transport,
    sid: &str,
    space: Space,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Asset>, CoreError> {
    let query: Vec<(&str, String)> = vec![
        ("api", browse_item_api(space).to_string()),
        ("version", version.to_string()),
        ("method", "list".to_string()),
        ("offset", offset.to_string()),
        ("limit", limit.to_string()),
        ("additional", "[\"thumbnail\",\"resolution\"]".to_string()),
        ("_sid", sid.to_string()),
    ];
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: ItemList = decode_envelope(&body)?;
    let total = parsed.list.len();
    let mut skipped = 0usize;
    let assets: Vec<Asset> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let item: RawItem = decode_one(raw, "browse item")?;
            let additional = item.additional.unwrap_or_default();
            let cache_key = additional.thumbnail.map(|t| t.cache_key).unwrap_or_default();
            if cache_key.is_empty() {
                tracing::warn!(
                    "skipping browse item (id={}): missing cache_key, not usable for thumbnails/downloads",
                    item.id
                );
                skipped += 1;
                return None;
            }
            let (width, height) = match additional.resolution {
                Some(r) => (r.width, r.height),
                None => (None, None),
            };
            Some(Asset {
                id: item.id,
                cache_key,
                filename: item.filename.unwrap_or_else(|| item.id.to_string()),
                media_kind: parse_media_kind(&item.kind),
                taken_at: item.time,
                added_at: item.create_time,
                width,
                height,
                file_size: item.filesize,
                space,
                server_version: item.version,
            })
        })
        .collect();
    let hard_skipped = total - (assets.len() + skipped);
    if hard_skipped > 0 || skipped > 0 {
        tracing::warn!(
            "browse item list: skipped {} of {} elements ({} failed to decode, {} missing cache_key)",
            hard_skipped + skipped,
            total,
            hard_skipped,
            skipped
        );
    }
    Ok(assets)
}

/// `SYNO.Foto.Browse.Album` / `SYNO.FotoTeam.Browse.Album`, `method=list`.
/// Space-aware the same way as `list_items`: API name resolved via
/// `namespace`, and every returned `Album.space` is set to the requested
/// `space`. Requests `additional=["thumbnail"]` so each album carries a
/// cover `cache_key` when DSM has one to offer.
///
/// Decoding is per-element and tolerant, same as `list_items`: an element
/// that fails to deserialize into `RawAlbum` (most commonly a missing/
/// renamed `id`, the minimum viable identity for an `Album`) is skipped and
/// logged via `tracing::warn!` rather than failing the whole page. A
/// missing `name` still produces a usable `Album` (falls back to the id).
///
/// `syno_token` is forwarded the same way as `list_items`: see that
/// function's doc comment.
pub async fn list_albums(
    transport: &Transport,
    sid: &str,
    space: Space,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Album>, CoreError> {
    let query: Vec<(&str, String)> = vec![
        ("api", browse_album_api(space).to_string()),
        ("version", version.to_string()),
        ("method", "list".to_string()),
        ("offset", offset.to_string()),
        ("limit", limit.to_string()),
        ("additional", "[\"thumbnail\"]".to_string()),
        ("_sid", sid.to_string()),
    ];
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: AlbumList = decode_envelope(&body)?;
    let total = parsed.list.len();
    let albums: Vec<Album> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let album: RawAlbum = decode_one(raw, "browse album")?;
            let cover_cache_key = album.additional.and_then(|a| a.thumbnail).map(|t| t.cache_key);
            Some(Album {
                id: album.id,
                name: album.name.unwrap_or_else(|| album.id.to_string()),
                item_count: album.item_count,
                cover_cache_key,
                space,
            })
        })
        .collect();
    let skipped = total - albums.len();
    if skipped > 0 {
        tracing::warn!("browse album list: skipped {} of {} elements (failed to decode)", skipped, total);
    }
    Ok(albums)
}
