//! `SYNO.Foto.Browse.Item` `method=delete`: the raw, PERMANENT delete verb
//! (and its `FotoTeam` counterpart).
//!
//! This is the one destructive call in the crate. Verified against the real
//! NAS 2026-07-25 (see `documentation/phase0-probe-results.md`): it removes
//! the item from the Photos index and moves the physical original into the
//! home `#recycle` folder, recoverable for the recycle bin's retention window
//! but with NO Synology Photos API to list or restore it. That is why the
//! everyday delete is a reversible move into an app album (`album_write.rs`),
//! and this verb is reached ONLY through the gated `permanently_delete` facade
//! method, which refuses to call it for any asset not already sitting in the
//! app trash (see `photoscore`'s `permanently_delete` and its `WriteRefused`
//! guard). Nothing else in the crate should call this directly.
//!
//! Request shape (VERIFIED): `id=[ids]` as a JSON array, version 7 (advertised
//! range 1..7; any pinned value works). Dispatched through the shared
//! `/webapi/entry.cgi` endpoint with `_sid` in the body and the X-SYNO-TOKEN
//! header, same as every other write. Success is a bare `{"success":true}`
//! with NO `data` field, so it decodes through `decode_write_success` (which
//! tolerates the missing `data`), never `decode_envelope` (which would fail
//! closed on it).

use crate::envelope::decode_write_success;
use crate::namespace::browse_item_api;
use crate::transport::Transport;
use models::{CoreError, Space};

/// Reuse the album-write array formatter so the `id=[...]` shape is identical
/// across every write call in the crate.
use crate::album_write::json_int_array;

/// `SYNO.Foto.Browse.Item` `method=delete`: permanently delete `item_ids`
/// from the Photos index (the original file lands in the home `#recycle` as a
/// filesystem-level safety net, see the module doc comment). Fails closed on
/// `success:false`; a bare `{"success":true}` is Ok.
pub async fn permanent_delete(
    transport: &Transport,
    sid: &str,
    space: Space,
    item_ids: &[i64],
    version: u32,
    syno_token: Option<&str>,
) -> Result<(), CoreError> {
    let version_str = version.to_string();
    let ids = json_int_array(item_ids);
    let form: Vec<(&str, &str)> = vec![
        ("api", browse_item_api(space)),
        ("version", &version_str),
        ("method", "delete"),
        ("id", &ids),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}
