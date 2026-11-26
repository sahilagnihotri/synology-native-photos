# FC fix notes: photoscore facade, crawl and reconcile

### MOCK-1: FIXED
- commit: 6d5c7c5
- test: `core_tests::empty_recently_deleted_permanently_deletes_each_path` in core/photoscore/src/lib.rs
- failed before the fix: with FA's uncommitted `ensure_is_recycled_file` in the working tree, `empty ok: UnexpectedResponse { message: "refusing to delete a.jpg: it is not listed in /home/#recycle/Photos" }`
- passes after: `cargo test -p photoscore`: `test result: ok. 66 passed; 0 failed; 0 ignored` (lib)
- changed tests: the fixture only. It now serves one listing that shows `a.jpg` as a file (`expect(1)`, asserted), then the empty listing the post delete poll needs. The check itself is untouched.
- left open: none. Not run without FA's check (that file is FA's and was uncommitted when I committed this); the fixture only adds one listing, so it should also suit the old code, unmeasured.

### R1-3c: FIXED
- commit: ee27208
- tests: `crawl::tests::full_page_with_a_skipped_item_does_not_end_the_crawl`, `delta::tests::skipped_id_keeps_its_local_row_and_later_pages_are_read`, `delta::tests::skipped_item_is_picked_up_once_it_decodes` (core/sync-engine, in-memory `test_support::SkippingSource`); `core_tests::crawl_reads_past_a_full_page_with_an_item_missing_its_cache_key` (200 element page, id 50 without cache_key, then a page at offset 200) and `core_tests::reconcile_keeps_a_local_row_whose_id_was_skipped` (core/photoscore, localhost mockito)
- failed before the fix: sync-engine `left: [0] right: [0, 2, 4]` (crawl stopped after page 0), `left: [0, 2] right: [0, 2, 4]`, `left: [1, 2, 4] right: [1, 2, 4, 5]`; photoscore `one undecodable item must not fail the crawl: Decode { message: "browse item list: element 49 of 200 is unusable (id 50 has no cache_key); refusing a short page" }` and the same for the reconcile (element 2 of 3, id 5)
- passes after: `cargo test -p sync-engine`: 25 passed, 0 failed, 0 ignored; `cargo test -p photoscore`: 68 passed, 0 failed, 0 ignored (lib)
- design: new `sync_engine::ListedPage { assets, total, raw_count, skipped_ids }` and a `PageSource::list_page` method with a default that wraps `list_items` (raw_count = decoded count, no skips), so every existing test source keeps working unchanged. `Crawler` and `DeltaReconciler` call `list_page`, advance the offset by `raw_count` and stop when `raw_count < limit`; the reconcile adds `skipped_ids` to the seen set before the deletion mirror and the sweep guard. `ApiPageSource::list_page` uses `synology_api::list_items_page` and synthesizes `total` from `raw_count`. Page errors still fail the crawl. Plain Rust, no UniFFI change.
- changed tests: none
- left open: a crawl whose only gap is a skipped item still flips the completion barrier (the end of the space was reached); the skipped item enters the index at the next Refresh (reconcile), not at the next crawl, because a completed crawl is a no-op.

### R2-2: FIXED (Disabled); Unknown is NEEDS RULING
- commit: 8ab1b83
- tests: `core_tests::delete_assets_refuses_when_the_recycle_bin_is_disabled` (localhost mockito, delete mock `expect(0)` asserted, User.Home mock asserted, local row stays) and `core_tests::delete_assets_proceeds_when_the_recycle_bin_is_enabled`
- failed before the fix: `panicked at core/photoscore/src/lib.rs:3568:14` (`a delete with the recycle bin off must be refused`, delete_assets returned Ok after sending the delete); the Enabled test failed on the unhit User.Home mock
- passes after: `cargo test -p photoscore`: 70 passed, 0 failed, 0 ignored (lib)
- design: `delete_assets` calls `synology_api::recycle_bin_status` under `trash_lock`, after the session check and before `permanent_delete`, and returns `CoreError::CapabilityUnavailable` on Disabled. A Network or Auth error from the status read fails the delete closed. No UniFFI change (existing variant).
- changed tests: none. Existing delete tests have no User.Home mock; mockito answers 501, which `recycle_bin_status` maps to Unknown, so they still exercise the delete.
- NEEDS RULING (Unknown): the Mac `DeleteController.requestDelete` deliberately raises the confirm for `.unknown` with "may be permanent" wording, and `confirmDelete` sends the delete. Refusing Unknown in the core would make delete impossible for a non-admin account. Options: (a) keep as is; (b) refuse Unknown too and accept that non-admin accounts cannot delete; (c) add an exported `delete_assets_confirmed_permanent` style flag (FFI change, needs ruling).

### R2-5: FIXED
- commit: 5ec9f7e
- tests: `core_tests::restore_session_with_auth_failure_reports_expired_without_error` (mock now answers SYNO.API.Info with success anonymously, like DSM, and the authenticated Browse.Item list for `SID-STALE` with error 119) and `core_tests::restore_session_with_valid_probe_populates_live` (now asserts the authenticated list carrying the saved sid was sent once)
- failed before the fix: `panicked at core/photoscore/src/lib.rs:1680:9: got Valid` for the stale sid; the Valid test failed on the unhit authenticated list mock
- passes after: `cargo test -p photoscore`: 70 passed, 0 failed, 0 ignored (lib)
- design: after `probe_capabilities`, `restore_session` calls `list_items_page(Personal, offset 0, limit 1)` with the saved sid and SynoToken at the pinned Browse.Item version. Auth or OtpRequired from either call gives `Expired`; any other error propagates. No UniFFI change.
- changed tests: the two restore tests' fixtures (the old expired fixture failed Info itself, which DSM never does).
- left open: a personal space that answers 801 (not enabled) would now make restore return an error rather than Valid. Not seen on the real NAS (Personal is the working space); unmeasured for other accounts.

### R2-6: FIXED (queue the local removal)
- commit: 1974d3f
- test: `core_tests::delete_assets_while_the_store_is_busy_queues_the_local_removal` (localhost mockito; takes the store out as `run_with_store` does, deletes, then returns it through `return_store`)
- failed before the fix: `a NAS delete that succeeded is not reported as failed: Storage { message: "store busy: a crawl or reconcile is in progress" }` (the delete mock was hit, so the NAS delete had happened)
- also falsified the drain: with `return_store` not applying the queue, `left: [2, 1] right: [2]`; restored, passes
- passes after: `cargo test -p photoscore`: 71 passed, 0 failed, 0 ignored (lib)
- design: chose queueing over refusing before the network call. Refusing would have needed a store check before the await, and a crawl can still start between that check and the removal, so it does not close the window. New private field `pending_local_deletes: Mutex<Vec<(Space, Vec<i64>)>>`; `delete_assets` queues under the store guard when the store is out; new `return_store` drains the queue under the store guard before putting it back (lock order store, then queue). A failed queued removal stays queued. Applying after the crawl also removes a row the crawl re-upserted from a page fetched before the delete. No UniFFI change (private field).
- left open: while the crawl runs, the deleted item stays visible in the grid (the store cannot be read anyway while it is out); it disappears when the crawl returns. The JoinError arm of `run_with_store` never returns the store, so a queue there is never applied; a later reconcile drops those rows since the NAS no longer lists them.

### R2-8: FIXED (clear, not hide; no schema change)
- commit: 5945810
- tests: core/persistence `account::tests::{first_bind_adopts_the_existing_rows, same_account_keeps_the_index, a_different_account_clears_the_index_and_the_crawl_barrier, a_different_host_with_the_same_username_also_clears}`; core/photoscore `core_tests::signing_in_as_another_account_clears_the_index` (localhost mockito: alice, Alice again keeps rows and thumbnails, bob clears both, then a restored alice session clears bob's rows)
- failed before the fix: persistence (stub `bind_account`) 3 of 4 failed (`account.rs:94`, `:118`, `:142`); photoscore `another account must not see alice's rows`, `left: 1 right: 0`
- falsified the thumbnail clear: with it disabled, `another account must not see alice's cached thumbnails`; restored, passes
- passes after: `cargo test -p persistence`: 74 passed, 0 failed, 0 ignored; `cargo test -p photoscore`: 72 passed, 0 failed, 0 ignored (lib)
- design: identity `"{base_url lowercased}|{username lowercased}"` stored in the existing `schema_meta` key/value table under `account_identity`, so there is no schema change and no migration step (a migration test is therefore not applicable; the legacy case, a database with rows and no identity, is covered by `first_bind_adopts_the_existing_rows`). `Store::bind_account` runs in one transaction. `PhotosCore::bind_index_to_account` runs on `login` after DSM accepts the credentials and on `restore_session` once the session validates, both before `Live` is set. No UniFFI change.
- left open, for a ruling if wanted: (1) the old rows are DELETED, not hidden, so switching back to the first account costs a full re crawl (originals untouched; the index is a cache). Hiding would need an owner column on every mirrored table and a migration. (2) The same NAS reached by two names (LAN IP and MagicDNS) counts as two accounts and re crawls on each switch; the safe direction. (3) A legacy database is adopted by whichever account signs in first. (4) Login while a crawl holds the store fails with store busy.

### R2-10: FIXED
- commit: 1572682
- tests: `core_tests::restore_recently_deleted_partial_failure_keeps_the_kind_and_the_count` and `core_tests::empty_recently_deleted_partial_failure_keeps_the_kind_and_the_count` (localhost mockito; item 1 succeeds, item 2 fails with DSM 119)
- failed before the fix: restore `got UnexpectedResponse { message: "restored 1 of 2 item(s) before failing: authentication failed: synology session expired (code 119)" }`; empty `count missing: synology session expired (code 119)`
- passes after: `cargo test -p photoscore`: 74 passed, 0 failed, 0 ignored (lib)
- design: private `with_partial_progress(e, verb, done, total)` keeps the variant and prefixes the message for Auth, Network, Decode, UnexpectedResponse and Storage. No UniFFI change.
- left open: OtpRequired and WriteRefused have no text field, so a partial failure of those kinds keeps the kind but loses the count (adding a field is an FFI change); CapabilityUnavailable is left unchanged because its field names an API. A failure on the first item is returned unchanged (count 0).

### R4-12b: FIXED
- commit: 641aa16
- test: `core_tests::save_edited_photo_succeeds_when_only_the_reindex_fails` (localhost mockito: upload succeeds, reindex answers 119; both mocks asserted hit once)
- failed before the fix: `an uploaded edit is saved even if the re-index fails: Auth { message: "synology session expired (code 119)" }`
- passes after: `cargo test -p photoscore`: 75 passed, 0 failed, 0 ignored (lib)
- design: the reindex error is logged with `tracing::warn!` and the save returns Ok. Upload failures still propagate and still send no reindex (existing test). No UniFFI change.
- left open: the UI is not told the reindex failed (that needs a new return type, an FFI change), so the edited copy may take until the next reindex (a restore, or DSM's own indexing; unverified how soon DSM indexes on its own) to appear in the library.

### R2-12: FIXED
- commit: 6bc245f
- test: `core_tests::concurrent_atomic_cache_writes_never_collide_on_the_temp_name` (256 threads behind a barrier, each writing its own final file in one temp directory)
- failed before the fix, three runs: `8 of 256 writes failed: Some(Storage { message: "File exists (os error 17)" })`, then 30 of 256, then 16 of 256
- passes after: three runs green; `cargo test -p photoscore`: 76 passed, 0 failed, 0 ignored (lib)
- design: a function local `static AtomicU64` counter appended to the temp name (`.tmp-{pid}-{clock digest}-{seq}`). No UniFFI change.
- left open: none. Two processes sharing a pid cannot run at once, and the clock part still separates runs.

### R2-11: NEEDS RULING (not testable on this machine); no production change
- finding: on Windows `std::fs::rename` over a target another process holds open without delete sharing fails with access denied, so a re-download of an original the player still has open, or a thumbnail the image loader holds, fails.
- why skipped: the brief allows a fix only if it can be tested portably. On macOS a POSIX rename over an open file always succeeds, so a test here cannot fail before a fix. There is no Windows Rust target installed (`rustup target list --installed` shows only Apple targets) and no wine, so a `#[cfg(windows)]` test would never run and could not be falsified. Also unverified: whether Rust 1.97 std on Windows 10+ already renames with POSIX semantics (`FileRenameInfoEx`), which would make the finding moot for some readers; that needs a run on Windows.
- options: (a) on `cfg(windows)`, when the rename fails with PermissionDenied and `final_path` already exists, remove the temp file and treat the existing file as the result. Safe only because both callers write content keyed on a deterministic name (cache_key, unit_id plus cache_key), so the existing file holds the same bytes; it would serve a truncated file if one was ever left there. (b) give `download_original` a unique per call name instead of a deterministic one, so the open file is never the target (leaves more temp files to clean). (c) defer to the Windows UI work, where the reader's share mode is chosen, and record it in TODO.md. Recommendation: (c) now, (a) with a Windows CI run once a Windows runner exists.

### R2-8 review follow up (two findings from team-lead): FIXED
1. Fail closed on an index with no recorded owner
- commit: 0c3271c
- tests: persistence `account::tests::first_bind_over_unowned_rows_clears_them` (replaces `first_bind_adopts_the_existing_rows`, which pinned the fail open behaviour) and `account::tests::first_bind_over_an_empty_index_adopts_it`; photoscore `core_tests::first_login_over_an_unowned_index_clears_rows_and_thumbnails`
- failed before the fix: persistence `panicked at core/persistence/src/account.rs:116:9` (bind returned false and kept the rows); photoscore `rows with no recorded owner must not be shown` (`left: 1 right: 0`)
- falsified the empty adopt test: forcing a reset with no identity fails it (and three others); restored, passes
- design: `bind_account` resets when an identity is stored and differs, OR when none is stored and `index_has_rows` (any row in assets, albums or app_state, or a sync_state row with any recorded progress; default sync_state rows created by a read do not count). A reset clears the same tables as an account switch, and photoscore clears the thumbnail cache on any reset. The other account tests now bind an empty index before seeding, so they still exercise the switch path.
- cost: one fresh crawl after the upgrade, accepted by the ruling.
2. Bind and Live swap atomic with respect to syncs
- commit: 07c86b4
- test: `core_tests::a_crawl_from_the_previous_account_writes_nothing_after_a_sign_in` (localhost mockito: page source built under alice, sign in as bob, crawl with alice's source; list mock `expect(0)` asserted, index empty, crawl not complete)
- failed with the check disabled: `a crawl from the previous account must be refused, got Ok(CrawlProgress { space: Personal, done: 1, total: 1, complete: true })`; restored, passes
- chose: identity carried in `Live` and in `ApiPageSource`, checked inside `run_with_store` under the store lock that takes the store out, failing with `CoreError::Storage` (existing variant). Why not one lock across bind and swap: the crawl's source is built from `Live` before the store is taken, so a shared lock would have to be held from building the source until the store is taken, and around the network awaits of login, which the std mutexes here must never be held across. The check needs no new lock, and because the store stays out of the mutex for the whole run, a sign in during a crawl fails with store busy instead of rebinding under it. Both directions are covered: an old source after the bind is refused, and a bind during a crawl cannot happen.
- also: moved the `run_with_store` doc comment back onto its function (R2-8 had inserted `bind_index_to_account` under it); the identity format moved to a private `account_identity` helper. `crawl_space` now delegates to a private `crawl_with_source`. No UniFFI change.
- left open: a Refresh refused this way returns a Storage error asking to sync again; the UI shows its generic storage message for it.
