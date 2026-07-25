//! Album mutation writes on `SYNO.Foto.Browse.NormalAlbum` (create an album,
//! add/remove members) and `SYNO.Foto.Browse.Album` (delete a whole album),
//! plus their `FotoTeam` counterparts.
//!
//! These are the first STATE-CHANGING calls in this crate. They exist to
//! back the hybrid safe-delete feature: the everyday "delete" is a
//! reversible move into an app-owned `Recently Deleted` album (add_item), and
//! restore is `delete_item` from that album. Neither touches the raw Foto
//! delete verb (that is `delete_item.rs`, gated behind the trash step in the
//! `photoscore` facade).
//!
//! Request shapes VERIFIED against the real NAS 2026-07-25 (DSM 7.3.2, DS925+,
//! Personal space), see `documentation/phase0-probe-results.md`:
//!
//! | Operation | API | method | params | success |
//! |-----------|-----|--------|--------|---------|
//! | create | NormalAlbum | create | name, item=[] | data.album {id,...} |
//! | add | NormalAlbum | add_item | id=<album>, item=[ids] | data.error_list=[] |
//! | remove | NormalAlbum | delete_item | id=<album>, item=[ids] | bare success |
//! | delete album | Album | delete | id=[album] | bare success |
//!
//! Every call is dispatched through the shared `/webapi/entry.cgi` endpoint
//! (`Transport::post_form_text`), sends `_sid` in the body and the
//! `X-SYNO-TOKEN` header (DSM rejects a state-changing call without the token
//! with error 119, same as the read calls), and is space-aware via
//! `namespace`. Only Personal is exercised against the real NAS; the FotoTeam
//! mapping is kept for symmetry.
//!
//! DECODE: `create_album` returns a `data.album` payload and so goes through
//! `decode_envelope` (which fails closed if that payload is missing on a
//! success response). The other three return either a `data.error_list` or a
//! bare `{"success":true}` with no `data`, so they route through
//! `decode_write_success`, which tolerates the missing `data` but still fails
//! closed on `success:false` and on a non-empty `error_list`.

use crate::envelope::{decode_envelope, decode_write_success};
use crate::namespace::{browse_album_api, normal_album_api};
use crate::transport::Transport;
use models::{Album, CoreError, Space};
use serde::Deserialize;

/// Formats an i64 id slice as the JSON array string DSM expects for the
/// `item`/`id` array params, e.g. `[1,2,3]` (or `[]` for an empty slice).
/// Mirrors the `format!("[{unit_id}]")` convention in `download.rs`, extended
/// to a multi-id array.
pub(crate) fn json_int_array(ids: &[i64]) -> String {
    let parts: Vec<String> = ids.iter().map(|id| id.to_string()).collect();
    format!("[{}]", parts.join(","))
}

#[derive(Debug, Deserialize)]
struct CreateAlbumData {
    album: RawCreatedAlbum,
}

/// The new album object returned under `data.album` by `create`. Decoded
/// tolerantly (unknown fields ignored): only `id` is required, `name`/
/// `item_count` default when absent, and the cover/flags are not returned by
/// create so they are filled with the same neutral defaults `list_albums`
/// uses for an album with no cover.
#[derive(Debug, Deserialize)]
struct RawCreatedAlbum {
    id: i64,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    item_count: u32,
}

/// `SYNO.Foto.Browse.NormalAlbum` `method=create`: create an empty album
/// named `name` and return it (with its server-assigned `id`). `item=[]` is
/// sent so the album starts empty; members are added later via `add_items`.
///
/// Returns the created `models::Album`, with `space` set to the requested
/// space and cover/flags defaulted (create does not report them). Fails
/// closed on `success:false` or a missing `data.album` (via
/// `decode_envelope`).
pub async fn create_album(
    transport: &Transport,
    sid: &str,
    space: Space,
    name: &str,
    version: u32,
    syno_token: Option<&str>,
) -> Result<Album, CoreError> {
    let version_str = version.to_string();
    let form: Vec<(&str, &str)> = vec![
        ("api", normal_album_api(space)),
        ("version", &version_str),
        ("method", "create"),
        ("name", name),
        ("item", "[]"),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    let data: CreateAlbumData = decode_envelope(&body)?;
    Ok(Album {
        id: data.album.id,
        name: data.album.name.unwrap_or_else(|| name.to_string()),
        item_count: data.album.item_count,
        cover_cache_key: None,
        cover_unit_id: None,
        is_shared: false,
        is_smart: false,
        space,
    })
}

/// `SYNO.Foto.Browse.NormalAlbum` `method=add_item`: add `item_ids` to the
/// album `album_id`. Success is `{"success":true,"data":{"error_list":[]}}`;
/// a non-empty `error_list` fails closed (see `decode_write_success`).
pub async fn add_items(
    transport: &Transport,
    sid: &str,
    space: Space,
    album_id: i64,
    item_ids: &[i64],
    version: u32,
    syno_token: Option<&str>,
) -> Result<(), CoreError> {
    let version_str = version.to_string();
    let album_id_str = album_id.to_string();
    let items = json_int_array(item_ids);
    let form: Vec<(&str, &str)> = vec![
        ("api", normal_album_api(space)),
        ("version", &version_str),
        ("method", "add_item"),
        ("id", &album_id_str),
        ("item", &items),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}

/// `SYNO.Foto.Browse.NormalAlbum` `method=delete_item`: remove `item_ids`
/// from the album `album_id`. This is the restore-from-trash primitive: it
/// removes an item's membership in the `Recently Deleted` album without
/// deleting the item itself. Success is a bare `{"success":true}`.
pub async fn remove_items(
    transport: &Transport,
    sid: &str,
    space: Space,
    album_id: i64,
    item_ids: &[i64],
    version: u32,
    syno_token: Option<&str>,
) -> Result<(), CoreError> {
    let version_str = version.to_string();
    let album_id_str = album_id.to_string();
    let items = json_int_array(item_ids);
    let form: Vec<(&str, &str)> = vec![
        ("api", normal_album_api(space)),
        ("version", &version_str),
        ("method", "delete_item"),
        ("id", &album_id_str),
        ("item", &items),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}

/// `SYNO.Foto.Browse.Album` `method=delete`: delete the whole album
/// `album_id`. Note the generic `.Album` API here, NOT `.NormalAlbum`
/// (verified against the real NAS). `id` is sent as a single-element array
/// `[album_id]`. Success is a bare `{"success":true}`.
///
/// Deleting the album never deletes the items it contained: DSM removes only
/// the album grouping, leaving each photo in the library.
pub async fn delete_album(
    transport: &Transport,
    sid: &str,
    space: Space,
    album_id: i64,
    version: u32,
    syno_token: Option<&str>,
) -> Result<(), CoreError> {
    let version_str = version.to_string();
    let id_array = json_int_array(&[album_id]);
    let form: Vec<(&str, &str)> = vec![
        ("api", browse_album_api(space)),
        ("version", &version_str),
        ("method", "delete"),
        ("id", &id_array),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn json_int_array_formats_empty_single_and_multi() {
        assert_eq!(json_int_array(&[]), "[]");
        assert_eq!(json_int_array(&[7]), "[7]");
        assert_eq!(json_int_array(&[1, 2, 3]), "[1,2,3]");
    }
}
