//! Album delete write on `SYNO.Foto.Browse.Album` (delete a whole album),
//! plus its `FotoTeam` counterpart.
//!
//! Create, add-item and remove-item writes used to live here for the old
//! "Recently Deleted" album flow. That flow is gone, so they were removed;
//! see git history if an albums feature needs them again.
//!
//! Request shape VERIFIED against the real NAS 2026-07-25 (DSM 7.3.2, DS925+,
//! Personal space), see `documentation/phase0-probe-results.md`:
//! `SYNO.Foto.Browse.Album` `delete`, `id=[album]`, bare success.
//!
//! The call is dispatched through the shared `/webapi/entry.cgi` endpoint
//! (`Transport::post_form_text`), sends `_sid` in the body and the
//! `X-SYNO-TOKEN` header (DSM rejects a state-changing call without the token
//! with error 119), and is space-aware via `namespace`. It returns a bare
//! `{"success":true}`, so it routes through `decode_write_success`, which
//! fails closed on `success:false` and on a non-empty `error_list`.

use crate::envelope::decode_write_success;
use crate::namespace::browse_album_api;
use crate::transport::Transport;
use models::{CoreError, Space};

/// Formats an i64 id slice as the JSON array string DSM expects for the
/// `item`/`id` array params, e.g. `[1,2,3]` (or `[]` for an empty slice).
/// Mirrors the `format!("[{unit_id}]")` convention in `download.rs`, extended
/// to a multi-id array.
pub(crate) fn json_int_array(ids: &[i64]) -> String {
    let parts: Vec<String> = ids.iter().map(|id| id.to_string()).collect();
    format!("[{}]", parts.join(","))
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
