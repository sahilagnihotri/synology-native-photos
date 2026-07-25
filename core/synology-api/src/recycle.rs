//! DSM home recycle-bin access for the "real delete" flow, via File Station.
//!
//! The everyday delete now removes an item from the Photos library outright
//! (`SYNO.Foto.Browse.Item` `method=delete`, see `delete_item.rs`), which
//! makes it vanish from Synology Photos everywhere (web app, phone) and moves
//! the physical original into the home recycle bin at the MIRRORED path
//! (VERIFIED against the real NAS 2026-07-25): deleting
//! `/home/Photos/iPhone/2016/09/IMG_0924.JPG` lands it at
//! `/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG`. The Photos index knows
//! nothing about that recycle bin, so this module browses/restores/empties it
//! with DSM File Station instead, keyed on filesystem paths rather than Photos
//! item ids. This is the "Recently Deleted" safety net (recoverable for the
//! recycle bin's retention window).
//!
//! Every call is dispatched through the shared `/webapi/entry.cgi` endpoint
//! (same as the rest of the crate, NOT a `/photo/...` path) and, like the
//! Photos state-reading/writing calls, sends the `X-SYNO-TOKEN` header on top
//! of `_sid` (DSM answers a token-auth session without it with error 119).
//!
//! Request shapes (from the feature brief's real-NAS reconnaissance; the exact
//! param encodings below are FOLLOWED FROM the brief and File Station
//! precedent, to be confirmed against the live NAS by the main session, which
//! owns the real-NAS probe):
//!
//! | Operation | API | ver | method | key params |
//! |-----------|-----|-----|--------|------------|
//! | list one folder | `SYNO.FileStation.List` | 2 | `list` | `folder_path`, `additional=["size","time","real_path"]` |
//! | restore (move) | `SYNO.FileStation.CopyMove` | 3 | `start` | `path=[src]`, `dest_folder_path`, `overwrite=false` |
//! | empty (delete) | `SYNO.FileStation.Delete` | 2 | `start` | `path=[...]` |
//! | thumbnail | `SYNO.FileStation.Thumb` | 2 | `get` | `path`, `size` |
//! | re-index Photos | `SYNO.Foto.Index` | 1 | `reindex` | (none) |
//!
//! DECODE: `List` returns a JSON envelope (`data.files`) and goes through the
//! tolerant `decode_envelope`; the `CopyMove`/`Delete`/`reindex` writes answer
//! with a bare `{"success":true}` (or a `data.taskid`) and route through
//! `decode_write_success` (which tolerates the missing/extra `data` but still
//! fails closed on `success:false`); `Thumb` answers with raw image bytes and
//! reuses `map_binary_or_error` so a JSON error is never handed back as image
//! data.

use crate::envelope::{decode_envelope, decode_write_success, map_binary_or_error};
use crate::transport::Transport;
use models::{media_kind_from_filename, CoreError, RecycleItem};
use serde::Deserialize;

/// The Photos subtree inside the DSM home recycle bin. Files deleted from the
/// Photos library land here at their mirrored original path.
const RECYCLE_PHOTOS_ROOT: &str = "/home/#recycle/Photos";

/// Bounds on the recursive recycle walk, so a pathological tree can never make
/// `list_recycle_photos` run away: cap how deep we descend and how many files
/// we collect in total.
const MAX_DEPTH: usize = 6;
const MAX_FILES: usize = 5000;

/// Per-folder page size for `SYNO.FileStation.List`.
const LIST_PAGE_LIMIT: u32 = 1000;

/// One decoded File Station directory entry (a file or a subfolder), after the
/// tolerant per-element decode.
struct FsEntry {
    is_dir: bool,
    name: String,
    path: String,
    size: u64,
    mtime: i64,
}

#[derive(Debug, Deserialize)]
struct FsListData {
    #[serde(default)]
    files: Vec<serde_json::Value>,
}

#[derive(Debug, Deserialize)]
struct RawFsFile {
    #[serde(default)]
    isdir: bool,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    additional: RawFsAdditional,
}

#[derive(Debug, Default, Deserialize)]
struct RawFsAdditional {
    #[serde(default)]
    size: Option<u64>,
    #[serde(default)]
    time: Option<RawFsTime>,
}

#[derive(Debug, Default, Deserialize)]
struct RawFsTime {
    /// Modification time in unix seconds. For a file in `#recycle`, this is
    /// when it was moved into the recycle bin, i.e. when it was deleted.
    #[serde(default)]
    mtime: Option<i64>,
}

/// Tolerantly decode one `data.files` element into an `FsEntry`, returning
/// `None` (skip) for a malformed element or one missing the minimum viable
/// identity (`name` and `path`). Mirrors `browse.rs`'s per-element tolerance:
/// one bad entry in a listing must never fail the whole walk.
fn decode_fs_entry(value: &serde_json::Value) -> Option<FsEntry> {
    let raw: RawFsFile = serde_json::from_value(value.clone()).ok()?;
    let name = raw.name.filter(|s| !s.is_empty())?;
    let path = raw.path.filter(|s| !s.is_empty())?;
    let size = raw.additional.size.unwrap_or(0);
    let mtime = raw.additional.time.as_ref().and_then(|t| t.mtime).unwrap_or(0);
    Some(FsEntry { is_dir: raw.isdir, name, path, size, mtime })
}

/// GET the shared entry.cgi dispatcher and return the raw response body, with
/// the throttle applied and the `X-SYNO-TOKEN` header attached when present.
/// Mirrors `browse::get_body` (which is crate-private to that module).
async fn fs_get_body(
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
        .map_err(|e| CoreError::Network { message: format!("file station request failed: {e}") })?;
    response
        .text()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading file station response body failed: {e}") })
}

/// Lists a SINGLE folder (not recursive) via `SYNO.FileStation.List`, paging
/// to exhaustion. Returns every decoded entry (files and subfolders); the
/// caller decides how to recurse. A per-element decode failure is skipped, not
/// propagated.
async fn list_folder(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
    folder_path: &str,
) -> Result<Vec<FsEntry>, CoreError> {
    let mut out: Vec<FsEntry> = Vec::new();
    let mut offset = 0u32;
    loop {
        let query: Vec<(&str, String)> = vec![
            ("api", "SYNO.FileStation.List".to_string()),
            ("version", "2".to_string()),
            ("method", "list".to_string()),
            ("folder_path", folder_path.to_string()),
            ("additional", r#"["size","time","real_path"]"#.to_string()),
            ("offset", offset.to_string()),
            ("limit", LIST_PAGE_LIMIT.to_string()),
            ("_sid", sid.to_string()),
        ];
        let body = fs_get_body(transport, &query, syno_token).await?;
        let data: FsListData = decode_envelope(&body)?;
        let n = data.files.len() as u32;
        for value in &data.files {
            if let Some(entry) = decode_fs_entry(value) {
                out.push(entry);
            }
        }
        if n < LIST_PAGE_LIMIT {
            break;
        }
        offset += LIST_PAGE_LIMIT;
    }
    Ok(out)
}

/// Walk `/home/#recycle/Photos` recursively (bounded), collect every file as a
/// `RecycleItem`, sort most-recently-deleted first, then apply `offset`/`limit`.
///
/// If the recycle root does not exist (a fresh account that has never deleted
/// anything), returns an empty vec rather than an error: File Station answers a
/// missing folder with a non-auth error, which is folded into "nothing to
/// list" here. An `Auth`/`OtpRequired` error (a genuinely bad session) still
/// propagates. A bad SUBfolder is tolerated (its subtree is skipped) so one
/// unreadable directory never fails the whole listing.
pub async fn list_recycle_photos(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
    offset: u32,
    limit: u32,
) -> Result<Vec<RecycleItem>, CoreError> {
    let mut items: Vec<RecycleItem> = Vec::new();
    // DFS stack of (folder_path, depth); the root is depth 0.
    let mut stack: Vec<(String, usize)> = vec![(RECYCLE_PHOTOS_ROOT.to_string(), 0)];

    'walk: while let Some((folder, depth)) = stack.pop() {
        let entries = match list_folder(transport, sid, syno_token, &folder).await {
            Ok(entries) => entries,
            Err(err) => {
                if matches!(err, CoreError::Auth { .. } | CoreError::OtpRequired) {
                    return Err(err);
                }
                if depth == 0 {
                    // The recycle root is absent: an empty bin, not a failure.
                    return Ok(Vec::new());
                }
                // Tolerate an unreadable subfolder: skip its subtree.
                continue;
            }
        };
        for entry in entries {
            if entry.is_dir {
                if depth < MAX_DEPTH {
                    stack.push((entry.path, depth + 1));
                }
            } else {
                items.push(RecycleItem {
                    media_kind: media_kind_from_filename(&entry.name),
                    recycle_path: entry.path,
                    filename: entry.name,
                    deleted_at: entry.mtime,
                    file_size: entry.size,
                });
                if items.len() >= MAX_FILES {
                    break 'walk;
                }
            }
        }
    }

    // Newest deletion first (mtime DESC), stable so equal mtimes keep order.
    items.sort_by(|a, b| b.deleted_at.cmp(&a.deleted_at));

    let start = (offset as usize).min(items.len());
    let end = start.saturating_add(limit as usize).min(items.len());
    Ok(items[start..end].to_vec())
}

/// Derive the ORIGINAL parent folder a recycled file should be restored into,
/// by removing the first `/#recycle/` segment from its recycle path and then
/// stripping the filename. Example:
/// `/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG`
/// -> `/home/Photos/iPhone/2016/09`.
///
/// Fails closed with `UnexpectedResponse` if the path carries no `#recycle`
/// segment (so it cannot be a recycle path) or has no parent directory at all,
/// so a restore never guesses a destination.
pub(crate) fn original_parent_folder(recycle_path: &str) -> Result<String, CoreError> {
    const MARKER: &str = "/#recycle/";
    let idx = recycle_path.find(MARKER).ok_or_else(|| CoreError::UnexpectedResponse {
        message: format!("recycle path has no '#recycle' segment: {recycle_path}"),
    })?;
    // Replace the first "/#recycle/" with a single "/", collapsing
    // ".../#recycle/Photos/..." back to ".../Photos/...".
    let mut original = String::with_capacity(recycle_path.len());
    original.push_str(&recycle_path[..idx]);
    original.push('/');
    original.push_str(&recycle_path[idx + MARKER.len()..]);

    match original.rsplit_once('/') {
        Some((parent, file)) if !file.is_empty() && !parent.is_empty() => Ok(parent.to_string()),
        // A file sitting directly under the filesystem root.
        Some((parent, file)) if !file.is_empty() && parent.is_empty() => Ok("/".to_string()),
        _ => Err(CoreError::UnexpectedResponse {
            message: format!("recycle path has no restorable parent directory: {recycle_path}"),
        }),
    }
}

/// JSON-encode a single path as the one-element array string File Station
/// expects for its `path` param, e.g. `["/home/#recycle/Photos/a.jpg"]`.
/// Using `serde_json` (not `format!`) so a path containing a quote or
/// backslash is escaped correctly rather than producing malformed JSON.
fn json_path_array(path: &str) -> Result<String, CoreError> {
    serde_json::to_string(&[path]).map_err(|e| CoreError::UnexpectedResponse {
        message: format!("could not encode file station path: {e}"),
    })
}

/// Restore one recycled file to its original library location by MOVING it out
/// of `#recycle` with `SYNO.FileStation.CopyMove` (`method=start`,
/// `overwrite=false`). The destination is derived by `original_parent_folder`.
///
/// `remove_src=true` is REQUIRED (verified against the real NAS): CopyMove
/// defaults to a copy, which leaves the file duplicated in `#recycle` after a
/// restore (so a restored item keeps showing in Recently Deleted).
/// `remove_src=true` makes it a true move, deleting the source once the copy
/// lands. Fails closed on a non-success envelope. `CopyMove start` returns a
/// `taskid`; a success envelope is treated as OK (no status poll).
pub async fn restore_recycle_item(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
    recycle_path: &str,
) -> Result<(), CoreError> {
    let dest = original_parent_folder(recycle_path)?;
    let path_array = json_path_array(recycle_path)?;
    let form: Vec<(&str, &str)> = vec![
        ("api", "SYNO.FileStation.CopyMove"),
        ("version", "3"),
        ("method", "start"),
        ("path", &path_array),
        ("dest_folder_path", &dest),
        ("overwrite", "false"),
        ("remove_src", "true"),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}

/// PERMANENTLY delete one recycled file with `SYNO.FileStation.Delete`
/// (`method=start`). This is unrecoverable (it empties the file from the
/// recycle bin). Fails closed on a non-success envelope.
pub async fn delete_recycle_item(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
    recycle_path: &str,
) -> Result<(), CoreError> {
    let path_array = json_path_array(recycle_path)?;
    let form: Vec<(&str, &str)> = vec![
        ("api", "SYNO.FileStation.Delete"),
        ("version", "2"),
        ("method", "start"),
        ("path", &path_array),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}

/// Render a thumbnail for a recycled file via `SYNO.FileStation.Thumb`
/// (`method=get`), returning the raw image bytes. `size` is passed through as
/// the `size` query param (File Station's own scale keywords). Reuses
/// `map_binary_or_error`, so a JSON error envelope is mapped to a `CoreError`
/// rather than handed back as bogus image bytes. UNVERIFIED against the real
/// NAS for a `#recycle` path: if Thumb rejects recycle paths, callers should
/// fall back to a placeholder on the resulting `CoreError`.
pub async fn recycle_thumbnail(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
    recycle_path: &str,
    size: &str,
) -> Result<Vec<u8>, CoreError> {
    transport.throttle().await;
    let query: Vec<(&str, String)> = vec![
        ("api", "SYNO.FileStation.Thumb".to_string()),
        ("version", "2".to_string()),
        ("method", "get".to_string()),
        ("path", recycle_path.to_string()),
        ("size", size.to_string()),
        ("_sid", sid.to_string()),
    ];
    let mut request = transport.client().get(transport.entry_url()).query(&query);
    if let Some(token) = syno_token {
        request = request.header("X-SYNO-TOKEN", token);
    }
    let response = request
        .send()
        .await
        .map_err(|e| CoreError::Network { message: format!("recycle thumbnail request failed: {e}") })?;
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.to_string());
    let bytes = response
        .bytes()
        .await
        .map_err(|e| CoreError::Network { message: format!("reading recycle thumbnail body failed: {e}") })?;
    map_binary_or_error(content_type.as_deref(), &bytes)
}

/// Trigger a Photos re-index with `SYNO.Foto.Index` (`method=reindex`, no
/// params), so items restored out of `#recycle` are picked back up into the
/// Photos library. Fails closed on a non-success envelope.
pub async fn trigger_reindex(
    transport: &Transport,
    sid: &str,
    syno_token: Option<&str>,
) -> Result<(), CoreError> {
    let form: Vec<(&str, &str)> = vec![
        ("api", "SYNO.Foto.Index"),
        ("version", "1"),
        ("method", "reindex"),
        ("_sid", sid),
    ];
    let body = transport.post_form_text(&form, syno_token).await?;
    decode_write_success(&body)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn original_parent_strips_recycle_and_filename() {
        assert_eq!(
            original_parent_folder("/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG").unwrap(),
            "/home/Photos/iPhone/2016/09"
        );
    }

    #[test]
    fn original_parent_handles_a_shallow_recycle_path() {
        assert_eq!(
            original_parent_folder("/home/#recycle/Photos/IMG.JPG").unwrap(),
            "/home/Photos"
        );
    }

    #[test]
    fn original_parent_errors_without_a_recycle_segment() {
        // A path that never passed through the recycle bin has no derivable
        // origin, so restore must refuse rather than guess.
        let err = original_parent_folder("/home/Photos/iPhone/IMG.JPG").unwrap_err();
        assert!(matches!(err, CoreError::UnexpectedResponse { .. }), "got {err:?}");
    }

    #[test]
    fn json_path_array_wraps_and_escapes() {
        assert_eq!(json_path_array("/home/#recycle/Photos/a.jpg").unwrap(), r#"["/home/#recycle/Photos/a.jpg"]"#);
        // A quote in the path is escaped, not left to break the JSON.
        assert_eq!(json_path_array(r#"/home/#recycle/a"b.jpg"#).unwrap(), r#"["/home/#recycle/a\"b.jpg"]"#);
    }

    #[test]
    fn decode_fs_entry_reads_file_facts() {
        let value = serde_json::json!({
            "isdir": false,
            "name": "IMG_0924.JPG",
            "path": "/home/#recycle/Photos/iPhone/2016/09/IMG_0924.JPG",
            "additional": { "size": 2500000, "time": { "mtime": 1600000000 } }
        });
        let entry = decode_fs_entry(&value).expect("valid file decodes");
        assert!(!entry.is_dir);
        assert_eq!(entry.name, "IMG_0924.JPG");
        assert_eq!(entry.size, 2_500_000);
        assert_eq!(entry.mtime, 1_600_000_000);
    }

    #[test]
    fn decode_fs_entry_skips_entry_without_path() {
        let value = serde_json::json!({ "isdir": false, "name": "orphan.jpg" });
        assert!(decode_fs_entry(&value).is_none());
    }

    #[test]
    fn decode_fs_entry_defaults_missing_size_and_time_to_zero() {
        let value = serde_json::json!({
            "isdir": false, "name": "a.jpg", "path": "/home/#recycle/Photos/a.jpg"
        });
        let entry = decode_fs_entry(&value).expect("decodes with defaults");
        assert_eq!(entry.size, 0);
        assert_eq!(entry.mtime, 0);
    }
}
