
## r3-persistence-models review, 2026-11-26

Baseline at HEAD: `cargo test -p persistence -p models` 61 + 23 passed, 0 failed. Throwaway probe test (deleted, never committed) measured every EXECUTED claim. All five leads from the stale pass were re-checked against HEAD; four still hold (R3-1 to R3-4), the Session Debug leak is fixed.

### R3-1: reconcile and delete batches fail for any library above 32,766 assets
- severity: high
- confidence: high
- location: core/persistence/src/assets.rs:259 (also :594 `delete_assets`)
- defect: `delete_assets_not_in` and `delete_assets` bind one `?N` per id. Bundled SQLite caps variables at 32766, and the error text embeds the whole SQL string.
- failure scenario: 40,000 asset library, `DeltaReconciler::reconcile` (core/sync-engine/src/delta.rs:122) passes 40,000 keep ids, the DELETE errors, so reconcile returns Err after upserting and server-side deletions are never mirrored. Permanent delete of more than 32,766 selected items fails the same way.
- evidence: EXECUTED. 40,000 rows, `delete_assets_not_in(Personal, &(1..=40000))` and `delete_assets` both returned `Err(Storage { message: "variable number must be between ?1 and ?32766 in DELETE FROM assets WHERE space = ?1 AND server_id ...`
- suggested fix: sweep via a TEMP table of seen ids (`DELETE ... NOT IN (SELECT id FROM temp)`), chunk `delete_assets` at 500 inside one transaction, and do not embed the SQL in the error.
- suggested test: 40,000 rows, keep 39,999, assert exactly one deleted and Ok.

### R3-2: grid ORDER BY defeats the index, every page sorts the whole space
- severity: medium
- confidence: high
- location: core/persistence/src/assets.rs:300 and :367 (`fetch_assets`, `filter_assets`)
- defect: `ORDER BY (taken_at IS NULL) ASC, taken_at DESC, ...` is redundant because SQLite already sorts NULL last under DESC. The extra term makes the planner pick `idx_assets_space_trash` and a TEMP B-TREE sort of all non-trashed rows. The doc comment claiming an index-only scan is false. `date_histogram` has the same shape (temp b-trees for GROUP BY and ORDER BY).
- failure scenario: 100,000 assets, file DB, grid asks for a page.
- evidence: EXECUTED. `EXPLAIN QUERY PLAN`: with the term `SEARCH ... idx_assets_space_trash (space=? AND in_trash=?)` + `USE TEMP B-TREE FOR ORDER BY`; without it `SEARCH ... idx_assets_space_taken (space=?)` and no sort. Page at offset 50000, limit 200, 100k rows: 123 ms with the term versus 27 ms without (4.5x). Offset 0 was measured at 27.5 ms versus 0.1 ms in the earlier pass. `date_histogram` 57 to 62 ms per call at 100k rows.
- suggested fix: drop `(taken_at IS NULL) ASC,` in both queries (`located_assets` already omits it), ideally make the index `(space, in_trash, taken_at DESC, server_id DESC)`.
- suggested test: assert `EXPLAIN QUERY PLAN` of the grid query contains no `TEMP B-TREE`; keep `null_taken_at_sorts_last`.

### R3-3: data-bearing migrations skip spaces whose crawl was still in progress
- severity: medium
- confidence: high
- location: core/persistence/src/schema.rs:282 (`reset_crawl_barrier_for_completed_spaces`, `WHERE initial_crawl_complete != 0`)
- defect: a space mid-crawl keeps its `last_offset` after a v3 (EXIF, rating) or v4 (GPS) upgrade, so the crawl resumes past rows that still hold the stale defaults. The delta reconciler later skips rows whose `server_version` is unchanged (delta.rs:87), so those rows are never refreshed. The code comment says a partial cursor is "exactly what a resumed crawl expects", which is wrong for a data-bearing column. The same hole will bite the next `requires_recrawl` step.
- failure scenario: DB at v2 with 5,000 of 10,000 items crawled, app updated. Items 1 to 5,000 never get GPS, rating or EXIF.
- evidence: EXECUTED. v2 DB with `initial_crawl_complete=0, last_offset=5000`, reopened: `last_offset=5000` afterwards (a completed space was rewound to 0, as designed).
- suggested fix: when any applied step has `requires_recrawl`, set `last_offset = 0, last_page_limit = 0` for every sync_state row, not only completed ones.
- suggested test: migrate a v2 DB with an incomplete cursor and assert `last_offset == 0`.

### R3-4: reconcile sweep wipes the whole space when the listing ends early or empty (persistence half)
- severity: medium
- confidence: medium
- location: core/persistence/src/assets.rs:272 (called from core/sync-engine/src/delta.rs:122; owner of the call site is r2)
- defect: `delete_assets_not_in` with an empty or short keep list deletes everything else, and the test `delete_assets_not_in_with_empty_keep_list_clears_the_space` pins the wipe as intended. Nothing in persistence or the caller sanity-checks the keep list against `expected_total`.
- failure scenario: DSM returns an empty or short page with success mid-listing (session race, hiccup): every local row beyond the last seen id, or the entire library, is dropped until a full re-crawl.
- evidence: EXECUTED for the persistence half (`delete_assets_not_in(Personal, &[])` on 3 rows deleted 3). READ-ONLY for the DSM behaviour.
- suggested fix: refuse the sweep when `keep_ids` is empty and local rows exist, or when it would remove more than a set fraction of rows, or when `seen_ids` disagrees with the page `total`.
- suggested test: sync-engine test with an empty first page for a populated space asserting nothing is deleted.

### R3-5: hand-rolled transactions can strand an open transaction
- severity: low
- confidence: medium
- location: core/persistence/src/assets.rs:233, :286, :594
- defect: `COMMIT` failures are propagated with `?` and no `ROLLBACK`. After a failed COMMIT the connection stays in the transaction and every later `BEGIN` fails with "cannot start a transaction within a transaction". `BEGIN` is deferred and no `busy_timeout` is set explicitly (rusqlite default 5 s).
- evidence: READ-ONLY (a failing COMMIT is hard to provoke here); the 5 s busy wait was measured in the earlier pass.
- suggested fix: `conn.unchecked_transaction()` or a rollback-on-drop guard.
- suggested test: inject a failing COMMIT and assert a later `upsert_assets` succeeds.

### R3-6: a database from a newer app version is opened, accepted and its version mirror overwritten
- severity: low
- confidence: high
- location: core/persistence/src/schema.rs:225 (`run_migrations`, no `current > latest_version()` check)
- defect: no downgrade guard. The old build opens a v9 file, carries on, and any NOT NULL column it does not know about breaks every upsert.
- evidence: EXECUTED. `user_version = 9` DB: `open_at` returned Ok, `schema_version()` returned 9, `user_version` stayed 9. (The NOT NULL write failure was shown in the earlier pass; this pass confirmed only the open.)
- suggested fix: return `CoreError::Storage` when `current > latest_version()`.
- suggested test: set `user_version = latest + 1`, assert `open_at` errors.

### R3-7: histogram buckets are UTC and truncate toward zero
- severity: low
- confidence: high
- location: core/persistence/src/assets.rs:430 (`date_histogram`)
- defect: `taken_at / 86400` buckets by UTC day, so a photo at 00:30 local in UTC+2 lands on the previous day. Integer division truncates toward zero, so -86399..-1 share bucket 0 with 1970-01-01 and with the NULL sentinel `day_start = 0`. Millisecond values are not normalised (`1_700_000_000_000` gives `day_start 1699999920000`).
- evidence: EXECUTED. taken_at [-1, -86400, 0, 86399, 1.7e12] gave `[DayCount{1699999920000,1}, DayCount{0,3}, DayCount{-86400,1}]`. Counts still line up with the list order, so the grid does not break.
- suggested fix: floor division, and decide whether local-day bucketing is wanted (pass a UTC offset).
- suggested test: `taken_at = -1` must produce `day_start = -86400`.

### R3-8: reconcile loads the entire library into memory
- severity: low
- confidence: medium
- location: core/sync-engine/src/delta.rs:66 (uses `fetch_assets(space, 0, u32::MAX)`)
- defect: builds 100k full `Asset` structs (26 fields each) only to read `id` and `server_version`.
- evidence: EXECUTED. 100,000 rows fetched in 391 to 433 ms, plus the heap for all of them.
- suggested fix: add a persistence method returning `(server_id, server_version)` pairs.
- suggested test: none needed beyond equivalence of the new method.

### R3-9: tests that cannot fail or pin the hazard
- severity: low
- confidence: high
- location: core/models/src/lib.rs `crate_marker_is_present` and `asset_holds_all_contract_fields` (lines shifted since the earlier pass, search by name); core/persistence/src/assets.rs `delete_assets_not_in_with_empty_keep_list_clears_the_space`
- defect: the first asserts a constant equals itself, the second asserts fields it just set, the third encodes the wipe in R3-4 as correct. No migration test covers a mid-crawl cursor (R3-3) or a newer `user_version` (R3-6).
- evidence: READ-ONLY.

### Checked and clean
- Session Debug leak (earlier lead): FIXED and complete. core/models/src/lib.rs:130 hand-written Debug masks sid, syno_token, device_did, test `session_debug_redacts_secrets` exists. `Connection.pinned_cert_der` still prints the DER, but that is a public certificate, not a secret.
- v5 migration (`clear_legacy_trash_flags`): unconditional `UPDATE ... SET in_trash=0, trashed_at=NULL`, idempotent, runs in the same BEGIN IMMEDIATE as the version bump. EXECUTED: v2 DB with 2 of 5 rows flagged reopened to `asset_count` 5. It cannot un-hide anything the product still hides, because no production code sets the flag any more (the queries keep `in_trash = 0`, harmless after the clear). The rows were never deleted on the NAS by the flag alone.
- Migration atomicity: all pending steps, the crawl barrier reset and `PRAGMA user_version` run inside one `BEGIN IMMEDIATE`/`COMMIT` with `ROLLBACK` on error. Each step is `PRAGMA table_info` guarded. A fresh DB runs every step as a no-op and ends at v5. `BASE_DDL` runs outside the transaction but is all `IF NOT EXISTS`.
- `upsert_asset` ON CONFLICT list omits `in_trash`/`trashed_at`. Paging: `server_id DESC` tiebreak is unique within a space, no repeats or skips. `filter_count` and `filter_assets` share `build_filter_where`; all-None equals `fetch_assets`/`asset_count`. No string-interpolated user text in SQL, no LIKE or search in this crate, no people or geolocation filters in persistence (located_assets is unwindowed by design).
- `LIMIT` with `u32::MAX` binds as i64, no overflow. Space isolation holds in every query. `Store` is one `Connection` behind photoscore's mutex.
- models has no serde decode (DSM decoding lives in synology-api, r1). `MediaKind::Unknown` and `int_to_media_kind` give a safe fallback. Minor: `int_to_space` maps any unknown int to Personal. Narrowing casts (`as u32`, `as i32`, `as u64`) on DB values are only reachable with corrupt rows.
