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
    #[serde(default)]
    list: Vec<RawItem>,
}

#[derive(Debug, Deserialize)]
struct RawItem {
    id: i64,
    filename: String,
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
    #[serde(default)]
    list: Vec<RawAlbum>,
}

#[derive(Debug, Deserialize)]
struct RawAlbum {
    id: i64,
    name: String,
    // ASSUMPTION (unverified): album size is reported as `item_count`.
    #[serde(default)]
    item_count: u32,
    #[serde(default)]
    additional: Option<ItemAdditional>,
}

/// Issue a GET against the shared entry.cgi dispatcher and return the raw
/// response body for `decode_envelope` to parse. Shared by `list_items` and
/// `list_albums` so both go through the same throttle/error-mapping path.
async fn get_body(transport: &Transport, query: &[(&str, String)]) -> Result<String, CoreError> {
    transport.throttle().await;
    let query_refs: Vec<(&str, &str)> = query.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let response = transport
        .client()
        .get(transport.entry_url())
        .query(&query_refs)
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
pub async fn list_items(
    transport: &Transport,
    sid: &str,
    space: Space,
    offset: u32,
    limit: u32,
    version: u32,
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
    let body = get_body(transport, &query).await?;
    let parsed: ItemList = decode_envelope(&body)?;
    Ok(parsed
        .list
        .into_iter()
        .map(|item| {
            let additional = item.additional.unwrap_or_default();
            let cache_key = additional.thumbnail.map(|t| t.cache_key).unwrap_or_default();
            let (width, height) = match additional.resolution {
                Some(r) => (r.width, r.height),
                None => (None, None),
            };
            Asset {
                id: item.id,
                cache_key,
                filename: item.filename,
                media_kind: parse_media_kind(&item.kind),
                taken_at: item.time,
                added_at: item.create_time,
                width,
                height,
                file_size: item.filesize,
                space,
                server_version: item.version,
            }
        })
        .collect())
}

/// `SYNO.Foto.Browse.Album` / `SYNO.FotoTeam.Browse.Album`, `method=list`.
/// Space-aware the same way as `list_items`: API name resolved via
/// `namespace`, and every returned `Album.space` is set to the requested
/// `space`. Requests `additional=["thumbnail"]` so each album carries a
/// cover `cache_key` when DSM has one to offer.
pub async fn list_albums(
    transport: &Transport,
    sid: &str,
    space: Space,
    offset: u32,
    limit: u32,
    version: u32,
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
    let body = get_body(transport, &query).await?;
    let parsed: AlbumList = decode_envelope(&body)?;
    Ok(parsed
        .list
        .into_iter()
        .map(|album| {
            let cover_cache_key = album.additional.and_then(|a| a.thumbnail).map(|t| t.cache_key);
            Album {
                id: album.id,
                name: album.name,
                item_count: album.item_count,
                cover_cache_key,
                space,
            }
        })
        .collect())
}
