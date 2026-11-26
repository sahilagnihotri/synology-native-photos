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
