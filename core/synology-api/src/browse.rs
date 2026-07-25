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
//! is matched against the media kinds we recognize (`photo`, `video`, and
//! `live` — a Live Photo, disambiguated by its sibling `live_type`); anything
//! else (a value we've simply never seen, e.g. a future `"burst"`) decodes as
//! `MediaKind::Unknown` rather than failing the whole list.
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
//!
//! VERIFIED against the real NAS: `additional.thumbnail.unit_id` sits next
//! to `cache_key` in the same thumbnail object, and it, not the item `id`,
//! is what the thumbnail/download endpoints key on. A thumbnail request
//! sent with the item id returns an html error page; the same request with
//! unit_id returns the real image bytes. See `thumbnail.rs`/`download.rs`.

use crate::envelope::decode_envelope;
use crate::namespace::{browse_album_api, browse_item_api};
use crate::transport::Transport;
use models::{Album, Asset, CoreError, MediaKind, SearchFilters, Space};
use serde::Deserialize;

/// A discovery-browse collection to filter `Browse.Item` by, plus the
/// query param name each one uses on the real NAS (see the discovery-browse
/// plan doc for the probe that confirmed every name below). All ids are
/// sent as a bare integer, NOT an array/bracket form and NOT quoted: DSM
/// rejects `geocoding_id=[756]` (error 120, reason "type") but accepts
/// `geocoding_id=756`, and the same bare-int shape was confirmed for
/// `person_id`; `general_tag_id` was confirmed accepted in the same bare
/// form (a made-up id returns a clean empty list rather than being
/// silently ignored, which is how an accepted-but-empty filter is told
/// apart from an unrecognized param that DSM just ignores).
///
/// `Favorites` has no id of its own: it sends `favorite=true`, which
/// genuinely filters `Browse.Item` to the caller's favorited items
/// (verified against the real NAS; there is no separate Favorite list API
/// to call instead).
///
/// `Album` sends `album_id=<id>`. VERIFIED against the real NAS: unlike
/// `condition_album_id`/`normal_album_id` (both tried first and found to be
/// silently ignored -- passing either alongside a made-up id still returned
/// the full, unfiltered library), `album_id` is genuinely validated by DSM:
/// a made-up id consistently answers with synology error 609 (no such
/// album) across `SYNO.Foto.Browse.Item` versions 1-7, which is the
/// signature of a real, checked filter rather than an ignored/unknown
/// param. Works for both normal and smart (condition) albums, since both
/// share the one `SYNO.Foto.Browse.Album` list surface.
///
/// Deliberately has no `Subject`/`Concept` variant: no working filter
/// param or dedicated item-list API was found for `SYNO.Foto.Browse.Concept`
/// on the real NAS (every candidate name tried was either explicitly
/// rejected or silently ignored; see the plan doc for the full list), so
/// there is nothing yet for a `Subject` collection to route to.
#[derive(Debug, Clone, Copy)]
pub enum CollectionFilter {
    Person(i64),
    Place(i64),
    Tag(i64),
    Favorites,
    Album(i64),
}

impl CollectionFilter {
    fn query_param(&self) -> (&'static str, String) {
        match self {
            CollectionFilter::Person(id) => ("person_id", id.to_string()),
            CollectionFilter::Place(id) => ("geocoding_id", id.to_string()),
            CollectionFilter::Tag(id) => ("general_tag_id", id.to_string()),
            CollectionFilter::Favorites => ("favorite", "true".to_string()),
            CollectionFilter::Album(id) => ("album_id", id.to_string()),
        }
    }
}

/// Map an item's `type` (and, for a Live Photo, its sibling `live_type`) to a
/// `MediaKind`.
///
/// VERIFIED against the real NAS: a Live Photo is TWO separate `Browse.Item`
/// items sharing one capture — a still `.JPG` (`type=live`, `live_type=photo`)
/// and a motion `.MOV` (`type=live`, `live_type=video`). `live_type` is what
/// tells the pair apart, so the `.MOV` component classifies as `Video` (and is
/// routed to the player / shows the grid play badge) while the `.JPG` stays
/// `Photo`. A `live` item with no `live_type` at all defaults to `Photo`: the
/// still image is the safe fallback (it never mis-routes a still to the video
/// player), and it matches the earlier behavior of showing a live capture as
/// an image.
///
/// Anything unrecognized (including future Synology media types we've never
/// seen) falls back to `MediaKind::Unknown` rather than failing the decode —
/// fail closed on the *meaning* of the type, not on the ability to list the
/// item at all.
fn parse_media_kind(kind: &str, live_type: Option<&str>) -> MediaKind {
    match kind {
        "photo" => MediaKind::Photo,
        "video" => MediaKind::Video,
        "live" => match live_type {
            Some("video") => MediaKind::Video,
            _ => MediaKind::Photo,
        },
        _ => MediaKind::Unknown,
    }
}

/// The `additional` keys requested on every `Browse.Item` list and every
/// `Search.Search list_item` call, kept in one place so the two paths stay in
/// lockstep. `thumbnail` yields `cache_key`/`unit_id` (needed for thumbnails/
/// downloads), `resolution` yields pixel dimensions, and `exif`/`description`/
/// `rating`/`video_meta` yield the per-asset metadata the info panel and the
/// rating filter consume. All four metadata blocks decode tolerantly, so
/// requesting them never risks failing an item on a DSM build that omits or
/// reshapes one.
const ITEM_ADDITIONAL: &str =
    "[\"thumbnail\",\"resolution\",\"exif\",\"description\",\"rating\",\"video_meta\"]";

/// The `additional` keys requested on `SYNO.Foto.Search.Search list_item`.
/// Deliberately leaner than `ITEM_ADDITIONAL`: `Search.Search` rejects the
/// enriched EXIF/description/rating/video_meta keys below version 3 (it answers
/// error 120 with `additional`/`condition`), and search shipped and was
/// verified on version 1, so it keeps the minimal thumbnail/resolution set and
/// stays on its verified version rather than moving just to satisfy metadata.
/// The crawl (`list_items`) still captures the richer metadata for every item,
/// so the library index has full info regardless of how an item was found.
const SEARCH_ADDITIONAL: &str = "[\"thumbnail\",\"resolution\"]";

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
    // VERIFIED against the real NAS: a Live Photo is two items sharing one
    // capture — a still `.JPG` (type=live, live_type=photo) and a motion
    // `.MOV` (type=live, live_type=video). `live_type` is present only on
    // `live` items; absent/other values decode to None (tolerant), and
    // `parse_media_kind` then treats a live item with no live_type as the
    // still (Photo).
    #[serde(default)]
    live_type: Option<String>,
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
    // Metadata enrichment (VERIFIED shapes against the real NAS). Requested
    // via `additional=[...,"exif","description","rating","video_meta"]`. Every
    // field is optional and tolerant: a missing block, a null, or a value that
    // arrives as a number where a string was expected all decode to a neutral
    // default rather than failing the item (same fail-open discipline as the
    // rest of this decoder).
    #[serde(default)]
    exif: Option<Exif>,
    #[serde(default, deserialize_with = "string_from_scalar")]
    description: String,
    #[serde(default, deserialize_with = "i32_from_scalar")]
    rating: i32,
    #[serde(default)]
    video_meta: Option<VideoMeta>,
}

/// `additional.exif`: per-photo EXIF. All fields VERIFIED to arrive as strings
/// (and often empty) on the real NAS, but decoded through `string_from_scalar`
/// so a build that reports one as a bare number (e.g. `iso: 100`) still
/// decodes instead of failing the item.
#[derive(Debug, Deserialize, Default)]
struct Exif {
    #[serde(default, deserialize_with = "string_from_scalar")]
    camera: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    aperture: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    exposure_time: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    focal_length: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    iso: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    lens: String,
}

/// `additional.video_meta`: per-video technical metadata. `duration` and
/// `framerate` may be numbers or strings across DSM builds, so both go through
/// `string_from_scalar` and are stored raw; width/height already come from
/// `resolution`. Fields this crate does not surface (audio_codec, bitrate,
/// rotation, ...) are simply ignored via the tolerant decode.
#[derive(Debug, Deserialize, Default)]
struct VideoMeta {
    #[serde(default, deserialize_with = "string_from_scalar")]
    duration: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    framerate: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    video_codec: String,
    #[serde(default, deserialize_with = "string_from_scalar")]
    container_type: String,
}

/// Tolerantly decode a JSON scalar the NAS reports for a metadata field into a
/// `String`. A string passes through; a number or bool is stringified (so a
/// build that sends `iso: 100` or `framerate: 29.97` still decodes); a null,
/// array, or object becomes "". Never errors, so one oddly-typed metadata
/// field can never fail the whole item.
fn string_from_scalar<'de, D>(de: D) -> Result<String, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    Ok(match Value::deserialize(de)? {
        Value::String(s) => s,
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => b.to_string(),
        // null / array / object: no meaningful scalar, treat as absent.
        _ => String::new(),
    })
}

/// Tolerantly decode `additional.rating` into an `i32`. Accepts a JSON number
/// (the verified shape) or a numeric string; anything else (null, non-numeric
/// string, ...) decodes as 0 (unrated) rather than failing the item.
fn i32_from_scalar<'de, D>(de: D) -> Result<i32, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde_json::Value;
    Ok(match Value::deserialize(de)? {
        Value::Number(n) => n.as_i64().unwrap_or(0) as i32,
        Value::String(s) => s.trim().parse::<i32>().unwrap_or(0),
        _ => 0,
    })
}

#[derive(Debug, Deserialize)]
struct Thumb {
    // ASSUMPTION (unverified): the thumbnail cache key needed for later
    // thumbnail/download calls is nested at `additional.thumbnail.cache_key`.
    #[serde(default)]
    cache_key: String,
    // VERIFIED against the real NAS: the id the thumbnail/download endpoints
    // actually key on lives here, at `additional.thumbnail.unit_id`, NOT on
    // the item's own `id`. A thumbnail GET with the item id returns an html
    // error page; with unit_id it returns the real image. Defaults to
    // absent (None) so a response that omits it (unexpected but not
    // impossible) does not fail decode; the caller falls back to 0 and logs
    // a warning rather than dropping the item.
    #[serde(default)]
    unit_id: Option<i64>,
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
    additional: Option<AlbumAdditional>,
    // ASSUMPTION (unverified against a real non-empty album; the probed
    // account has zero albums of either kind): DSM's community-documented
    // convention nests smart-album rule data under `condition` and shared-
    // album info under `sharing_info`. Presence of either object (regardless
    // of its own inner shape, which was never observed) is treated as the
    // marker for `is_smart`/`is_shared`; absence defaults both to `false`
    // rather than failing decode, so an unrecognized/renamed marker just
    // degrades to "normal, unshared" instead of breaking the whole list.
    #[serde(default)]
    condition: Option<serde_json::Value>,
    #[serde(default)]
    sharing_info: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, Default)]
struct AlbumAdditional {
    #[serde(default)]
    thumbnail: Option<Thumb>,
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
/// for (the item payload itself carries no space marker). Requests the shared
/// `ITEM_ADDITIONAL` key set so each item comes back with a `cache_key`
/// (needed for thumbnails/downloads), a `unit_id` (the id the thumbnail/
/// download endpoints actually key on, see the module doc comment), pixel
/// dimensions, and the per-asset metadata (EXIF, description, rating, video
/// metadata). Unknown item fields are ignored, every metadata block decodes
/// tolerantly, and an unrecognized `type` decodes as `MediaKind::Unknown`
/// rather than failing the whole list.
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
    list_items_inner(transport, sid, space, offset, limit, version, syno_token, None).await
}

/// Same as `list_items`, but additionally filters the returned rows to one
/// discovery-browse collection via `filter` (see `CollectionFilter` for the
/// confirmed query param each variant sends). Personal space only for now:
/// every `CollectionFilter` variant was verified only against
/// `SYNO.Foto.Browse.Item`, not the `FotoTeam` shared-space equivalent, so
/// this always targets `Space::Personal` regardless of what a caller might
/// otherwise pass; there is no shared-space discovery browse yet.
pub async fn list_items_filtered(
    transport: &Transport,
    sid: &str,
    filter: CollectionFilter,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Asset>, CoreError> {
    list_items_inner(transport, sid, Space::Personal, offset, limit, version, syno_token, Some(filter)).await
}

async fn list_items_inner(
    transport: &Transport,
    sid: &str,
    space: Space,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
    filter: Option<CollectionFilter>,
) -> Result<Vec<Asset>, CoreError> {
    let mut query: Vec<(&str, String)> = vec![
        ("api", browse_item_api(space).to_string()),
        ("version", version.to_string()),
        ("method", "list".to_string()),
        ("offset", offset.to_string()),
        ("limit", limit.to_string()),
        ("additional", ITEM_ADDITIONAL.to_string()),
        ("_sid", sid.to_string()),
    ];
    if let Some(filter) = filter {
        query.push(filter.query_param());
    }
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
            let thumb = additional.thumbnail;
            let cache_key = thumb.as_ref().map(|t| t.cache_key.clone()).unwrap_or_default();
            if cache_key.is_empty() {
                tracing::warn!(
                    "skipping browse item (id={}): missing cache_key, not usable for thumbnails/downloads",
                    item.id
                );
                skipped += 1;
                return None;
            }
            // unit_id (not the item id) is what the thumbnail/download
            // endpoints actually key on, verified against the real NAS. An
            // item that lacks it is still imported (so the grid count stays
            // correct) rather than dropped, but it defaults to 0, which
            // cannot be thumbnailed/downloaded, so this is logged loudly.
            let unit_id = thumb.and_then(|t| t.unit_id).unwrap_or_else(|| {
                tracing::warn!(
                    "browse item (id={}): missing additional.thumbnail.unit_id, thumbnails/downloads for it will fail (defaulting unit_id=0)",
                    item.id
                );
                0
            });
            let (width, height) = match additional.resolution {
                Some(r) => (r.width, r.height),
                None => (None, None),
            };
            let exif = additional.exif.unwrap_or_default();
            let video = additional.video_meta.unwrap_or_default();
            Some(Asset {
                id: item.id,
                unit_id,
                cache_key,
                filename: item.filename.unwrap_or_else(|| item.id.to_string()),
                media_kind: parse_media_kind(&item.kind, item.live_type.as_deref()),
                taken_at: item.time,
                added_at: item.create_time,
                width,
                height,
                file_size: item.filesize,
                space,
                server_version: item.version,
                rating: additional.rating,
                description: additional.description,
                camera: exif.camera,
                aperture: exif.aperture,
                exposure_time: exif.exposure_time,
                focal_length: exif.focal_length,
                iso: exif.iso,
                lens: exif.lens,
                duration: video.duration,
                framerate: video.framerate,
                video_codec: video.video_codec,
                container_type: video.container_type,
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

/// `SYNO.Foto.Search.Search`, `method=list_item`. Personal space only (no
/// `FotoTeam` equivalent probed or in scope; see the search plan doc for
/// the full probe transcript).
///
/// VERIFIED against the real NAS: the method name is `list_item`, not
/// `list` or `search` (both plausible guesses were rejected with error 103,
/// "no such method", even though `SYNO.API.Info` genuinely advertises the
/// API -- a different error code than an unknown API entirely, which is
/// what proves the API exists but the method name was wrong). The keyword
/// param is `keyword`, not `query` (confirmed by two controls: a
/// nonsense keyword value returns a clean empty list, proving `keyword`
/// genuinely filters; sending `query` instead of `keyword` returns error
/// 100 "invalid parameter" rather than being silently ignored, proving
/// `query` is not a valid alias). Results are flat, the same
/// `{"data":{"list":[...]}}` envelope as `Browse.Item`, not grouped into
/// people/places/tags sections.
///
/// Uses the lean `SEARCH_ADDITIONAL` key set: `cache_key`/`unit_id` under
/// `additional.thumbnail` and `width`/`height` under `additional.resolution`.
/// The enriched EXIF/rating/video_meta keys are omitted here on purpose (see
/// `SEARCH_ADDITIONAL`), so search stays on its verified version 1. Reuses
/// `RawItem`/`Asset` end to end: search rows have the exact same shape as
/// browse rows, so no new model or decoder was needed. Live Photos surface
/// here with
/// `type="live"` and are classified by their sibling `live_type` exactly as
/// on the browse path (`parse_media_kind`): the motion `.MOV` component is a
/// `Video`, the still `.JPG` a `Photo`.
///
/// Decoding is per-element and tolerant, same discipline as `list_items`:
/// a malformed row or one missing a usable `cache_key` is skipped and
/// logged rather than failing the whole page.
///
/// `syno_token` is forwarded the same way as `list_items`: see that
/// function's doc comment.
///
/// Delegates to `search_filtered` with an empty `SearchFilters` (no date
/// range), so a plain keyword search sends exactly the same request it
/// always has.
pub async fn search(
    transport: &Transport,
    sid: &str,
    keyword: &str,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Asset>, CoreError> {
    search_filtered(transport, sid, keyword, &SearchFilters::default(), offset, limit, version, syno_token).await
}

/// Same as `search`, but additionally narrows results to a `start_time`/
/// `end_time` unix-second range via `filters`.
///
/// VERIFIED against the real NAS (see `models::SearchFilters`'s doc
/// comment): `start_time`/`end_time` are the only facet-shaped filter
/// params confirmed to genuinely narrow `Search.Search list_item` results
/// -- every other candidate (`camera_id`, `aperture_id`, `geocoding_id`,
/// `item_type`, `media_type`, `folder_id`, `general_tag_id`, `person_id`,
/// `exposure_time_group_id`, and JSON-blob `condition`/`filter` params) was
/// probed with a real id alongside a bogus-id control and found to be
/// silently ignored: real and bogus returned byte-identical unfiltered
/// results. Only the params present in `filters` (`None` fields are omitted
/// entirely, never sent as an empty string) are added to the request, so a
/// default `SearchFilters` produces the exact same query `search` always
/// sent.
pub async fn search_filtered(
    transport: &Transport,
    sid: &str,
    keyword: &str,
    filters: &SearchFilters,
    offset: u32,
    limit: u32,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Vec<Asset>, CoreError> {
    let mut query: Vec<(&str, String)> = vec![
        ("api", "SYNO.Foto.Search.Search".to_string()),
        ("version", version.to_string()),
        ("method", "list_item".to_string()),
        ("keyword", keyword.to_string()),
        ("offset", offset.to_string()),
        ("limit", limit.to_string()),
        ("additional", SEARCH_ADDITIONAL.to_string()),
        ("_sid", sid.to_string()),
    ];
    if let Some(start) = filters.start_time {
        query.push(("start_time", start.to_string()));
    }
    if let Some(end) = filters.end_time {
        query.push(("end_time", end.to_string()));
    }
    let body = get_body(transport, &query, syno_token).await?;
    let parsed: ItemList = decode_envelope(&body)?;
    let total = parsed.list.len();
    let mut skipped = 0usize;
    let assets: Vec<Asset> = parsed
        .list
        .iter()
        .filter_map(|raw| {
            let item: RawItem = decode_one(raw, "search item")?;
            let additional = item.additional.unwrap_or_default();
            let thumb = additional.thumbnail;
            let cache_key = thumb.as_ref().map(|t| t.cache_key.clone()).unwrap_or_default();
            if cache_key.is_empty() {
                tracing::warn!(
                    "skipping search item (id={}): missing cache_key, not usable for thumbnails/downloads",
                    item.id
                );
                skipped += 1;
                return None;
            }
            let unit_id = thumb.and_then(|t| t.unit_id).unwrap_or_else(|| {
                tracing::warn!(
                    "search item (id={}): missing additional.thumbnail.unit_id, thumbnails/downloads for it will fail (defaulting unit_id=0)",
                    item.id
                );
                0
            });
            let (width, height) = match additional.resolution {
                Some(r) => (r.width, r.height),
                None => (None, None),
            };
            let exif = additional.exif.unwrap_or_default();
            let video = additional.video_meta.unwrap_or_default();
            Some(Asset {
                id: item.id,
                unit_id,
                cache_key,
                filename: item.filename.unwrap_or_else(|| item.id.to_string()),
                media_kind: parse_media_kind(&item.kind, item.live_type.as_deref()),
                taken_at: item.time,
                added_at: item.create_time,
                width,
                height,
                file_size: item.filesize,
                space: Space::Personal,
                server_version: item.version,
                rating: additional.rating,
                description: additional.description,
                camera: exif.camera,
                aperture: exif.aperture,
                exposure_time: exif.exposure_time,
                focal_length: exif.focal_length,
                iso: exif.iso,
                lens: exif.lens,
                duration: video.duration,
                framerate: video.framerate,
                video_codec: video.video_codec,
                container_type: video.container_type,
            })
        })
        .collect();
    let hard_skipped = total - (assets.len() + skipped);
    if hard_skipped > 0 || skipped > 0 {
        tracing::warn!(
            "search item list: skipped {} of {} elements ({} failed to decode, {} missing cache_key)",
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
/// `space`. This is the unified list covering both normal (user-created)
/// and smart/condition albums; DSM has no separate list method per type on
/// this surface (`SYNO.Foto.Browse.NormalAlbum`/`ConditionAlbum` exist but
/// were confirmed, against the real NAS, to expose only single-item `get`/
/// mutation methods, not their own `list`; both return an empty `list` on
/// this account, consistent with the unified `Browse.Album` being the real
/// source of truth for listing).
///
/// Requests `additional=["thumbnail"]` so each album carries a cover
/// `cache_key`/`unit_id` when DSM has one to offer. VERIFIED against the
/// real NAS: `sharing_info` and `provider_count` are also accepted
/// `additional` keys on this API (a `passphrase`/`condition` key in
/// `additional` is rejected outright with error 120, reason "condition"),
/// but the probed account has zero albums of either kind, so what either
/// key actually populates in a non-empty response was never captured; only
/// `thumbnail` is requested here until that is confirmed against real data.
///
/// Decoding is per-element and tolerant, same as `list_items`: an element
/// that fails to deserialize into `RawAlbum` (most commonly a missing/
/// renamed `id`, the minimum viable identity for an `Album`) is skipped and
/// logged via `tracing::warn!` rather than failing the whole page. A
/// missing `name` still produces a usable `Album` (falls back to the id).
/// `is_smart`/`is_shared` are best-effort (see `RawAlbum`'s doc comment):
/// absence of their marker fields defaults both to `false` rather than
/// failing decode.
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
            let thumb = album.additional.and_then(|a| a.thumbnail);
            let cover_cache_key = thumb.as_ref().map(|t| t.cache_key.clone());
            let cover_unit_id = thumb.and_then(|t| t.unit_id);
            Some(Album {
                id: album.id,
                name: album.name.unwrap_or_else(|| album.id.to_string()),
                item_count: album.item_count,
                cover_cache_key,
                cover_unit_id,
                is_shared: album.sharing_info.is_some(),
                is_smart: album.condition.is_some(),
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

#[cfg(test)]
mod tests {
    use super::parse_media_kind;
    use models::MediaKind;

    // The six-case classification table the media-enrichment brief locks in.
    // A Live Photo is two items: a still `.JPG` (live_type=photo) and a motion
    // `.MOV` (live_type=video); the latter must classify as Video so it routes
    // to the player, the former as Photo.
    #[test]
    fn live_video_component_is_video() {
        assert_eq!(parse_media_kind("live", Some("video")), MediaKind::Video);
    }
    #[test]
    fn live_photo_component_is_photo() {
        assert_eq!(parse_media_kind("live", Some("photo")), MediaKind::Photo);
    }
    #[test]
    fn live_without_live_type_defaults_to_photo() {
        assert_eq!(parse_media_kind("live", None), MediaKind::Photo);
    }
    #[test]
    fn plain_video_is_video() {
        assert_eq!(parse_media_kind("video", None), MediaKind::Video);
        // A stray live_type on a plain video is irrelevant: `type` wins.
        assert_eq!(parse_media_kind("video", Some("photo")), MediaKind::Video);
    }
    #[test]
    fn plain_photo_is_photo() {
        assert_eq!(parse_media_kind("photo", None), MediaKind::Photo);
    }
    #[test]
    fn unrecognized_type_is_unknown() {
        // A future/unseen type stays Unknown even if it carries a live_type.
        assert_eq!(parse_media_kind("burst", None), MediaKind::Unknown);
        assert_eq!(parse_media_kind("live_photo", Some("video")), MediaKind::Unknown);
        assert_eq!(parse_media_kind("", None), MediaKind::Unknown);
    }
}
