# r2-photoscore-sync review notes

## r2-photoscore-sync, 2026-11-26 17:40, against HEAD of main

Scope: `core/photoscore/` and `core/sync-engine/`. Throwaway probe tests were written to
`core/photoscore/tests/zz_review_r2-photoscore-sync_session.rs` and
`core/sync-engine/tests/zz_review_r2-photoscore-sync_delta.rs`, run, and deleted (never committed).
All mocks were local mockito servers; no NAS or other host was contacted.

### R2-1: delta reconcile fails outright for any library above 32,765 items
- severity: high
- confidence: high
- location: core/sync-engine/src/delta.rs:122
- defect: `reconcile` passes every server id it saw to `Store::delete_assets_not_in`, which binds one SQL
  variable per id. The bundled SQLite caps bound variables at 32,766, so the deletion mirror errors and the
  whole reconcile returns `Err` (after it already upserted the new rows, before it records `reconcile_at`).
- failure scenario: a 40,000 photo library (the project targets 20k to 100k). Every Refresh fails with a
  Storage error whose message embeds the entire 32k placeholder SQL string; photos deleted on the phone or the
  web never leave the local grid, ever.
- evidence: EXECUTED `cargo test -p sync-engine --test zz_review_r2-photoscore-sync_delta zz_large -- --nocapture`
  with 40,000 local rows, server listing of 39,999 plus one new: `large_result=Err(Storage { message:
  "variable number must be between ?1 and ?32766 in DELETE FROM assets WHERE space = ?1 AND server_id NOT IN (?2,?3,...`
- suggested fix: do the anti-join without bound parameters: insert the seen ids into a TEMP table (batched
  inserts) and `DELETE ... WHERE server_id NOT IN (SELECT id FROM temp_seen)`, or diff in Rust against the
  local id set and delete the missing ids in chunks of at most 500. Also truncate SQL text out of the error.
- suggested test: reconcile a 40,000 row store against a 39,999 plus 1 listing; assert `Ok`, count 40,000,
  the dropped id gone, the new id present. Fails today with the error above.

### R2-2: the "refuse delete when the recycle bin is off" rule lives only in the Swift UI, not the core
- severity: high
- confidence: high
- location: core/photoscore/src/lib.rs:986
- defect: `delete_assets` never calls `recycle_bin_status`; it sends `SYNO.Foto.Browse.Item delete`
  unconditionally. The only guard is `DeleteController.swift:90` in the Mac app, read at request time and
  separated from the actual delete (line 125) by the confirm dialog.
- failure scenario: the future Windows client (or any second caller of the facade) calls `delete_assets`
  without the pre-check while the DSM home recycle bin is off: the originals are deleted with no recovery path,
  breaking invariant 2. On the Mac, the bin can also be switched off in DSM while the confirm dialog is open,
  and the delete still goes through (TOCTOU).
- evidence: READ-ONLY. `grep -n recycle_bin_status core/photoscore/src/lib.rs` shows only the facade method
  and its own tests; no call from `delete_assets`. The existing delete tests (lib.rs:3284 onward) mock no
  status call and still pass, which proves the core needs none.
- suggested fix: inside `delete_assets`, under `trash_lock`, call `synology_api::recycle_bin_status` first and
  return a dedicated error (for example `CoreError::RecycleBinDisabled`) on `Disabled`, sending nothing.
  Decide explicitly what `Unknown` does (the planned least-privilege `photosclient` user will always read
  `Unknown`), for example an `allow_unknown_bin: bool` parameter the UI sets only after its warning.
- suggested test: mock status `enable_recycle_bin:false`, call `delete_assets`, assert the error and that the
  delete mock got `expect(0)`; local row still present.

### R2-3: a saved edit can be silently dropped: upload uses overwrite=false, which DSM treats as "skip"
- severity: medium
- confidence: medium
- location: core/photoscore/src/lib.rs:940 (relies on core/synology-api/src/upload.rs:77)
- defect: the facade doc says `overwrite=false` makes a name collision "fail closed". In File Station,
  `overwrite=false` means skip the upload when the file exists, answered as success (the project's own
  `recycle.rs:525` comment says exactly this for CopyMove, and the File Station guide says it for Upload);
  only OMITTING `overwrite` makes a collision an error. `decode_write_success` ignores `data`, so a skip
  (`blSkip`) reads as success. The core also does no validation of `filename` and does not make it unique:
  uniqueness rests on the Mac caller's `<base>-edited-<HHmmss>.jpg` (no date, flat `/home/Photos/Edited` folder).
- failure scenario: the user edits `IMG_1234.JPG` today at 10:15:00 and edits another `IMG_1234.JPG`
  (iPhone names wrap after 9999, or the same photo again) on another day at 10:15:00: the second upload is
  skipped, the UI says Saved, and the edit is lost. A Windows caller passing `a\b.jpg` or `..` is not
  stopped by the core at all.
- evidence: READ-ONLY. No real NAS probe allowed; the skip semantics come from the File Station API guide
  and the repo's own recycle.rs:523 to 526. Needs one measured upload of a duplicate name to confirm.
- suggested fix: omit `overwrite` (collision becomes an error), or check `data.blSkip` and fail; in the core,
  validate `filename` as a single safe component and append a collision-proof suffix (date plus time plus a
  short random or the asset id).
- suggested test: mock Upload answering `{"success":true,"data":{"blSkip":true}}`; assert
  `save_edited_photo` returns an error and sends no reindex.

### R2-4: an empty (or short) server listing wipes the whole local library
- severity: medium
- confidence: high
- location: core/sync-engine/src/delta.rs:110 and :122
- defect: the reconcile treats the first short page as the end of the listing and deletes every local row it
  did not see, with no sanity bound. A successful but empty or truncated listing (Photos mid re-index, a
  volume briefly unavailable, a DSM build that caps `limit` below 200) empties or truncates the mirror.
- failure scenario: 500 local photos, NAS answers `{"success":true,"data":{"list":[]}}` once: the grid shows
  0 photos and `initial_crawl_complete` stays true, so the crawl never refills it; only a later good Refresh does.
- evidence: EXECUTED `cargo test -p sync-engine --test zz_review_r2-photoscore-sync_delta -- --nocapture`:
  `before=500` then `result_ok=true after=0`.
- suggested fix: refuse the deletion mirror (keep upserts) when the listing is empty while local is non
  empty, or when it would delete more than a set share (for example 20 percent) of the space; surface a
  warning instead.
- suggested test: the empty-source case above asserts the count stays 500 and the result reports the refusal.

### R2-5: restore_session reports Valid for an expired session (the probe never sends the sid)
- severity: medium
- confidence: high
- location: core/photoscore/src/lib.rs:234
- defect: validation calls `synology_api::probe_capabilities(&transport)`, a `SYNO.API.Info query=all`
  request with no `_sid` and no SynoToken, which DSM answers without auth. The stored session is never
  tested, so `Expired` is unreachable in practice. The unit test
  `restore_session_with_auth_failure_reports_expired_without_error` (lib.rs:1581) passes only because its
  mock answers the anonymous Info call with error 400, a fixture built from the assumption, not DSM data.
- failure scenario: app relaunch a day later with a stale sid in the Keychain: AuthStateMachine goes to
  `.valid`, then every browse, thumbnail and delete fails with 119 instead of showing the login (or a
  device-token re-login).
- evidence: EXECUTED `cargo test -p photoscore --test zz_review_r2-photoscore-sync_session zz_restore -- --nocapture`
  with a mock that rejects requests carrying `_sid=SID-STALE` and serves Info anonymously:
  `restore_state=Ok(Valid)`.
- suggested fix: validate with a cheap authenticated call carrying the sid and SynoToken (for example
  `SYNO.Foto.Browse.Item list limit=1`, or `SYNO.Core.User.Home get`), mapping 105, 106, 107, 119 to `Expired`.
- suggested test: the probe above, asserting `Expired` and `live` empty.

### R2-6: delete during a crawl or Refresh deletes on the NAS, then reports failure
- severity: medium
- confidence: high
- location: core/photoscore/src/lib.rs:1006 to 1008
- defect: `delete_assets` sends the NAS delete first, then needs the store; while a crawl or reconcile owns
  the store (`run_with_store` took it out), it returns `store busy` after the irreversible server step.
  The local row stays (a ghost until the next reconcile) and the user is told the delete failed.
- failure scenario: user deletes a photo while the initial import or a Refresh runs: the photo is already in
  the recycle bin, the alert says the delete failed, the photo is still in the grid; a retry sends a second
  delete for an id that no longer exists.
- evidence: EXECUTED `zz_delete_during_crawl_reports_failure_after_nas_delete` (slow mocked list call):
  `delete_result=Err(Storage { message: "store busy: a crawl or reconcile is in progress" }) nas_delete_sent=true`.
- suggested fix: check store availability before the server call, or queue the local removal (a pending
  deletes set applied when `run_with_store` puts the store back) and return Ok once the NAS confirmed.
- suggested test: the probe above, asserting `Ok` and that the row is gone after the crawl ends.

### R2-7: every local read fails for the whole duration of a crawl or Refresh
- severity: medium
- confidence: high
- location: core/photoscore/src/lib.rs:1395 to 1398 (and every `store_busy_err` read site, e.g. :358, :375)
- defect: `run_with_store` removes the only `Store` for the entire crawl or reconcile, so `asset_count`,
  `fetch_assets`, `crawl_progress`, `date_histogram`, `filter_*` all return `store busy`. The doc comments
  claim reads only wait "for the instant of the swap". On the Mac, `WindowedDataSource.refreshCount`
  maps that error to `totalCount = 0`.
- failure scenario: a manual Refresh on a 40k library (minutes of paging): the grid goes empty or fails to
  page until it finishes; during the initial import the grid cannot show the photos already imported.
- evidence: EXECUTED `zz_local_reads_fail_during_crawl`: `fetch_assets_during_crawl=Err(Storage { message:
  "store busy: ..." })`, `asset_count_during_crawl=Err(...)`.
- suggested fix: give the crawler its own SQLite connection (WAL mode, a second `Store::open_at` on the same
  file) so the facade's read connection stays in place.
- suggested test: the probe above asserting both reads return `Ok` mid crawl.

### R2-8: signing in to another account or NAS reuses the previous account's index and skips the crawl
- severity: medium
- confidence: high
- location: core/photoscore/src/lib.rs:257 (sign_out) and :145 (one DB per core, not keyed by host or user)
- defect: `sign_out` clears `live` and thumbnails but keeps `photos.sqlite`, including
  `initial_crawl_complete=true`. A later login to a different user or host sees the old rows and
  `crawl_space` is a no-op.
- failure scenario: sign out of account A, sign in as B (or a replacement NAS whose Photos ids differ): B is
  shown A's library index (privacy), and deleting one of those stale rows sends A's id to B's NAS, where the
  same numeric id can be a different photo the user never selected.
- evidence: EXECUTED `zz_second_account_sees_first_accounts_index` (two mock NAS servers, ids 111 and 222):
  `after_switch crawl_complete=true ids=[111]`.
- suggested fix: record host plus username in the DB (or the DB file name) and reset the index and sync state
  when it changes; at minimum reset on `sign_out`.
- suggested test: the probe above asserting `ids=[222]`.

### R2-9: download_original and video playback hold the whole original in memory and re-download it every time
- severity: medium
- confidence: medium
- location: core/photoscore/src/lib.rs:862 to 877 and :908
- defect: `synology_api::download_original` returns the full body as a `Vec<u8>`, which is then written; there
  is no cache-hit check on the deterministic temp path, so every open re-downloads.
- failure scenario: opening a 3 GB 4K video: about 3 GB of RAM in the app process plus a full re-download on
  each open; on a constrained Mac or the Windows app this can be killed for memory.
- evidence: READ-ONLY.
- suggested fix: stream the response to the temp file chunk by chunk; return the existing file when present
  (the name already includes `cache_key`).
- suggested test: second call for the same unit id and cache key hits the download mock `expect(1)`.

### R2-10: restore and empty lose the error kind or the count on a partial failure
- severity: low
- confidence: high
- location: core/photoscore/src/lib.rs:1071 and :1099 to 1101
- defect: a mid-batch restore failure is rewrapped as `UnexpectedResponse`, so a session expiry (Auth) on item
  2 no longer reads as Auth to the app. A mid-batch permanent delete returns the raw error with no count, so
  the UI cannot say that some items were already permanently deleted.
- failure scenario: empty 10 items, item 4 fails: 3 are gone forever, UI shows a generic failure and may
  list them again until refreshed.
- evidence: READ-ONLY.
- suggested fix: keep the inner variant (a `Partial { done, total, source }` error, or pass Auth through
  unchanged), and report the count for empty too.
- suggested test: restore of two paths with the second answering 119: assert `CoreError::Auth`.

### R2-11: Windows: atomic cache write fails when the target is open
- severity: low
- confidence: medium
- location: core/photoscore/src/lib.rs:1223
- defect: `std::fs::rename` over an existing file maps to `MoveFileExW(REPLACE_EXISTING)`, which fails with
  access denied when another process or a non-Rust reader holds the target open without delete sharing.
  `download_original` always rewrites the same deterministic temp name.
- failure scenario: Windows app plays a video (player holds the file), user reopens it: re-download then rename
  fails, playback errors. Same for thumbnails opened by the UI image loader.
- evidence: READ-ONLY.
- suggested fix: reuse an existing file (R2-9 fix) and, on Windows, treat a failed rename over an existing
  complete file as a hit.
- suggested test: Windows-only test that opens the target with no delete sharing and calls the write.

### R2-12: temp file names can collide under concurrent thumbnail misses
- severity: low
- confidence: low
- location: core/photoscore/src/lib.rs:1197 to 1210
- defect: the temp name is pid plus a hash of `SystemTime` nanoseconds; macOS realtime clock reads are
  microsecond granular, so two concurrent misses on the multi-thread runtime in the same microsecond collide
  and the second `create_new` fails with a Storage error.
- failure scenario: grid scroll fires many thumbnail misses at once: an occasional cell shows the placeholder.
- evidence: READ-ONLY.
- suggested fix: add an `AtomicU64` counter to the name.
- suggested test: 256 concurrent thumbnail misses against a mock, assert zero errors.

### Checked and clean
- Stale lead `zz_empty_recently_deleted_accepts_library_path`: fixed at HEAD. `ensure_recycle_photos_path`
  (synology-api recycle.rs:328) refuses anything outside `/home/#recycle/Photos` and `.`/`..`/empty segments,
  checked for the whole batch before the lock and the first request; covered by lib.rs:3548 and :3584.
  Note: a recycle SUBFOLDER path (`/home/#recycle/Photos/2026`) passes the guard and would delete the whole
  folder, only reachable if a caller passes a folder entry.
- Stale lead `zz_restore_with_expired_sid_reports_valid`: still real, see R2-5.
- Stale lead `zz_empty_listing_wipes_local_library`: still real, see R2-4; `zz_large_library_reconcile`: see R2-1.
- Thumbnail traversal test (lib.rs:2380) does prove containment: it asserts the parent dir equals
  `{cache}/thumbs` canonically and the hashed name, not only absence of `..`.
- No std `Mutex` guard is held across an `.await` anywhere in the facade (checked every `lock()` site);
  `trash_lock` is a tokio mutex by design.
- Crawl panic is caught in `run_with_store` and the store is restored; UniFFI also catches panics, so an
  `expect` on a poisoned mutex does not abort the app.
- `restore_recently_deleted` does not reindex after a failed move, and checks every path before the first move.
- Crawl stop condition and completion barrier: `ApiPageSource` synthesizes `total`, so a short page always
  completes; no infinite loop (an empty page stops it). Resume uses the persisted cursor.
- No ghost row from the restore new-id behaviour: the old id's row is removed at delete time; the new id
  appears at the next reconcile (subject to R2-1 on big libraries).
- `cache_digest` uses `DefaultHasher` with fixed keys: deterministic within a toolchain; a toolchain change
  only orphans cache files. Not a defect.
- Mid-reconcile offset shift (a photo deleted elsewhere while paging) drops one live photo from the mirror and
  keeps the deleted one, EXECUTED: `server_now=[2..10] local_after=[10,9,8,7,5,4,3,2,1]`; it self-heals on the
  next reconcile, so recorded here as low rather than as a finding.
