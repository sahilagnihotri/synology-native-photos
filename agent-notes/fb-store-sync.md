# FB fix notes: persistence, sync-engine, models

### R3-1 (and R2-1): FIXED
- commit: c4319c2
- test: `delete_assets_not_in_handles_a_keep_set_above_the_variable_limit` and `delete_assets_handles_a_delete_set_above_the_variable_limit` in core/persistence/src/assets.rs (40,000 Personal rows plus one Shared row; exact survivor sets asserted)
- failed before the fix: `called Result::unwrap() on an Err value: Storage { message: "variable number must be between ?1 and ?32766 in DELETE FROM assets WHERE space = ?1 AND server_id NOT IN (?2,?3,...` (and the same for `server_id IN (...)`)
- passes after: `cargo test -p persistence`: `test result: ok. 63 passed; 0 failed; 0 ignored`; `cargo test -p sync-engine`: `ok. 17 passed; 0 failed; 0 ignored`
- changed tests: none
- left open: none. The keep set goes into `temp.reconcile_keep` and one `NOT IN (SELECT ...)` anti-join; `delete_assets` binds in chunks of 500 in one transaction. The error text can no longer carry a 32k placeholder string because no statement is that large any more.

### R2-4 (and R3-4): FIXED, with one open product question
- commit: 05240b6
- tests (core/sync-engine/src/delta.rs): `empty_listing_keeps_every_local_row` (500 rows, empty listing three times in a row, count stays 500, `reconcile_at` stays unset), `small_legitimate_deletion_is_applied` (500 rows, 10 gone, applied), `listing_over_the_threshold_is_refused_until_repeated` (500 rows, listing drops 300 and adds 1: first call refused with 501 rows kept, the identical second call applies and leaves 201), `a_different_short_listing_does_not_confirm_the_first`, plus `large_library_reconciles_past_the_sql_variable_limit` (R2-1 at the sync level, 40,000 rows, passes since c4319c2)
- failed before the fix: `empty listing must be refused, got Ok(CrawlProgress { space: Personal, done: 0, total: 0, complete: false })` and `first sight of a 60 percent drop must be refused, got Ok(CrawlProgress { space: Personal, done: 201, ... })`
- passes after: `cargo test -p sync-engine`: `test result: ok. 22 passed; 0 failed; 0 ignored`
- rule: `MAX_UNCONFIRMED_DELETE_PERCENT = 20` and `MIN_GUARDED_LOCAL_ROWS = 100` in delta.rs. An empty listing for a populated space is never applied, at any size. A non-empty listing that removes more than 20 percent of a space of 100+ rows is refused once; its id fingerprint (FNV-1a of the sorted ids, stored in `app_state` key `reconcile_pending_sweep`) is recorded, and the next reconcile that sees the identical listing applies it. A refusal still keeps the upserts (new and changed rows land), does not set `reconcile_at`, and returns `CoreError::UnexpectedResponse`. The Mac app shows it through `CoreError.userMessage` as "Unexpected response from the NAS. The NAS listing would remove N of M local items, so none were removed. Refresh again to confirm the change." No signature change.
- how the user reaches a correct state after really deleting most of a library on the NAS: press Refresh twice. The second reconcile sees the same listing and applies it. Note the brief's premise that "a later full crawl can still converge" does not hold in the code: `Crawler` only upserts and never deletes, and a completed crawl is a no-op, so only reconcile removes rows.
- left open (NEEDS RULING, small): a library emptied on purpose on the NAS (every item deleted) never converges, because an empty listing is never applied. Options: (a) keep it so (safest, stale rows stay until the user rebuilds the index, which has no UI today); (b) apply an empty listing on the second identical empty listing, like the share rule (one line change in `sweep_is_plausible`); (c) add an explicit "rebuild local index" action in photoscore and the app. My recommendation is (b) only if (c) is not wanted, since a wrongly applied sweep self-heals on the next good reconcile (every id is re-inserted as NEW).
- changed tests: none. `delete_assets_not_in_with_empty_keep_list_clears_the_space` in persistence still pins the primitive's literal semantics, which are correct for the primitive; the guard lives in the only caller.

### R3-3: FIXED
- commit: 09090ec
- test: `data_bearing_migration_rewinds_an_in_progress_crawl_cursor` in core/persistence/src/schema.rs (v2 DB, Personal at `initial_crawl_complete=0, last_offset=5000, last_page_limit=200`)
- failed before the fix: `assertion left == right failed: an in-progress crawl must restart from the beginning to backfill the new columns, left: 5000, right: 0`
- passes after: `cargo test -p persistence`: `test result: ok. 64 passed; 0 failed; 0 ignored`
- changed tests: none (the existing Shared all-zero row assertion still holds)
- left open: the private function keeps its name `reset_crawl_barrier_for_completed_spaces` (no renames rule); its doc comment now says it resets every space.

### R3-6: FIXED
- commit: 0719051
- test: `database_from_a_newer_version_is_refused_untouched` in core/persistence/src/schema.rs (user_version = latest + 1, a pre-existing schema_meta mirror value)
- failed before the fix: `a newer database must be refused, got Ok(())`
- passes after: `cargo test -p persistence`: `test result: ok. 65 passed; 0 failed; 0 ignored`
- changed tests: none
- left open: the refusal is `CoreError::Storage` with the message "the local database is from a newer version of the app (schema N, this build supports up to M); update the app to open it". The Mac app already shows store open failures as a terminal screen (`.storeFailed(error.userMessage)`), so no Swift change is needed for it to be visible. The check runs before BASE_DDL, so nothing at all is written to the newer file.

### R3-7 (core half of R5-4): FIXED
- commit: 80d4210
- test: `date_histogram_floors_negative_days_and_keeps_unknown_distinct_from_day_zero` in core/persistence/src/assets.rs (taken_at -86401, -86400, -1, 0, 100, 86399 and one NULL)
- failed before the fix: `left: [DayCount { day_start: 0, count: 4 }, DayCount { day_start: -86400, count: 2 }, DayCount { day_start: 0, count: 1 }]` against the expected `[0:3, -86400:2, -172800:1, UNKNOWN:1]` (truncation folded -1 into day 0, and the NULL bucket also used key 0)
- passes after: `cargo test -p persistence`: `test result: ok. 66 passed; 0 failed; 0 ignored`; `cargo test -p models`: `ok. 23 passed; 0 failed; 0 ignored`
- CONTRACT for the Swift worker: a NULL `taken_at` lands in one trailing bucket with `day_start = i64::MIN` (`Int64.min`), never 0. A timestamp within a day of the epoch buckets by floor: 0..=86399 gives `day_start = 0` (the real day 1970-01-01 UTC), -86400..=-1 gives `day_start = -86400`. Sent to fs-macos-app; the Swift spots still treating 0 as Unknown are GridDateSections.swift:120 and :127, PhotoGridSectioningTests.swift:83, FakePhotosCore.swift:346, DateSectionFormatterTests.swift:16 and :24. Until those change, an undated bucket would render with an absurd date header instead of "Unknown Date", but the duplicate section id trap from R5-4 is gone.
- changed tests: `date_histogram_puts_null_taken_at_in_trailing_zero_bucket` (asserted the colliding 0 sentinel, now asserts `UNKNOWN_DATE_DAY_START`; name kept), `date_histogram_boundaries_line_up_with_fetch_assets` (checked the sentinel as 0 and computed the day with truncating `/`; now uses the constant and `div_euclid`), `date_histogram_omits_unknown_bucket...` (compares with the constant). DayCount doc comment in core/models updated.
- left open: UTC bucketing kept (local-time bucketing is tracked separately). Millisecond `taken_at` values are still not normalised. A corrupt `taken_at` within 86400 of `i64::MIN` would overflow the floor expression into a REAL and fail the histogram read; not reachable with DSM second timestamps.
