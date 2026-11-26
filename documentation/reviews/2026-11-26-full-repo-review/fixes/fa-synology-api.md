# fa-synology-api notes (fix worker FA, 2026-11-26)

Scope: `core/synology-api/`. Findings from
`documentation/reviews/2026-11-26-full-repo-review/r1-synology-api.md`.

### R1-1: FIXED
- commit: bd53372
- test: `core/synology-api/tests/redirect_mock.rs` (login 307, permanent_delete 308, download 302, pinned client 307)
- failed before the fix: `login must fail on a redirect, got Ok(Session { ... })`, `delete must fail on a redirect, got Ok(())`, `download must fail on a redirect`, and on the pinned path `redirect target was contacted left: 1`
- passes after: `cargo test -p synology-api --test redirect_mock`: 4 passed, 0 failed. Whole crate: 221 passed, 0 failed, 1 ignored
- changed tests: none
- left open: none. A custom redirect policy refuses every hop with "refusing to follow a redirect (HTTP <status>)", so the 3xx surfaces as `CoreError::Network` through the existing reqwest error paths, and the Location URL is never put in the message.

### R1-2: FIXED
- commit: 27f3457
- test: `get_paths_never_leak_the_session_in_errors` in `core/synology-api/tests/secret_redaction.rs` (19 public GET or multipart entry points against the closed port `http://127.0.0.1:1`, checks `Display` and `Debug` for the sid and the SynoToken, and that the error is `Network`)
- failed before the fix: `list_items leaks the sid: network error: browse request failed: error sending request for url (http://127.0.0.1:1/webapi/entry.cgi?...&_sid=SECRETSID)`
- passes after: `cargo test -p synology-api --test secret_redaction`: 1 passed. Whole crate: 222 passed, 0 failed, 1 ignored
- changed tests: none
- left open: none. All 19 reqwest `{e}` sites now go through `transport::network_error` (crate-private), which calls `without_url()`. The remaining `{e}` formats are serde or x509 errors, which carry no URL. `tracing::warn!` sites log serde decode errors only.

### R1-7: FIXED
- commit: 9e70dec
- test: `download_non_2xx_text_body_is_an_error_not_file_bytes` in `core/synology-api/tests/download_mock.rs` (503, 502, 404 text/plain). Also added `download_non_2xx_json_envelope_keeps_its_error_mapping` as a guard (it passed before too; it pins that the fix keeps the envelope mapping)
- failed before the fix: `HTTP 503 must be an error, got Ok(Ok("Service Unavailable"))`
- passes after: `cargo test -p synology-api --test download_mock`: 8 passed. Whole crate: 224 passed, 0 failed, 1 ignored
- changed tests: none
- left open: none

### R1-10: FIXED
- commit: 9388894
- test: `pin_version_inverted_window_is_capability_unavailable_not_a_panic` in `core/synology-api/tests/info_mock.rs`
- failed before the fix: `panicked at core/synology-api/src/info.rs:105:16: min > max. min = 3, max = 2`
- passes after: whole crate 225 passed, 0 failed, 1 ignored
- changed tests: none
- left open: none. An inverted window returns `CapabilityUnavailable`, same as a missing API.

### R1-3: FIXED (synology-api half only)
- commit: 3965787
- test: `list_items_page_with_an_undecodable_element_fails_naming_it` in `core/synology-api/tests/browse_mock.rs` (one element with no id, one with no cache_key, each in the middle of a full page of 3)
- failed before the fix: `a full page must not come back short, got Ok([Asset { id: 901, .. }, Asset { id: 903, .. }])`
- passes after: whole crate 226 passed, 0 failed, 1 ignored
- changed tests: `one_malformed_item_is_skipped_others_still_decode` called `list_items` and asserted the drop (the defect). It now calls `list_items_filtered` with `CollectionFilter::Favorites`, which keeps pinning the tolerance on the display paths.
- scope decision: the strict check applies only to unfiltered `list_items`, the only list the photoscore crawl (`ApiPageSource`) pages through. `list_items_filtered`, `list_album_items`, `filter_items`, `search` and `search_filtered` stay tolerant because they feed views, not the reconcile. The API contract (`Vec<Asset>`) carries no raw count, so failing the page was the option that needs no signature change.
- left open (trade-off for the orchestrator): one item that is still waiting for its thumbnail (no cache_key yet) now makes the crawl fail at that page until DSM finishes, instead of silently truncating the index. That is safe (no local rows are dropped) but it stops the crawl. A gentler option is an additive `list_items_page` that returns the raw element count with the decoded assets so `ApiPageSource` can page on the raw count and keep the skip. That needs a photoscore change (not my paths). The sync-engine half of R1-3 (reconcile deletes on a short page) is not touched here.

### R1-6: FIXED
- commit: baea50e
- test: `list_recycle_photos_stops_when_paging_makes_no_progress`, `restore_precheck_stops_when_paging_makes_no_progress` and `restore_precheck_stops_at_the_page_cap` in `core/synology-api/tests/recycle_mock.rs`
- failed before the fix: the two no-progress tests hit their 10 s timeout (`the listing must not hang: Elapsed(())`, `the restore precheck must not hang: Elapsed(())`); the cap test failed with `paging must stop before the 40th page`
- passes after: whole crate 229 passed, 0 failed, 1 ignored
- changed tests: none
- left open: the cap is 32 pages (32 000 entries) per folder. A real folder larger than that now fails the listing or the restore precheck closed rather than being read in full. The no-progress check compares the first and last raw entries of consecutive full pages, so a server that returns different but overlapping pages is caught only by the cap.

### R1-4: FIXED
- commit: e942def
- test: `session_codes_map_to_auth`, `recycle_bin_status_surfaces_an_expired_session` and `restore_with_an_expired_session_is_auth_and_moves_nothing` in `core/synology-api/tests/session_expiry_mock.rs`
- failed before the fix: `code 106 should be Auth, got UnexpectedResponse { message: "unhandled synology error code 106" }`; `code 106: an expired session is not an unknown bin state, got Ok(Unknown)`; restore `got Err(UnexpectedResponse { message: "unhandled synology error code 119" })`
- passes after: whole crate 232 passed, 0 failed, 1 ignored
- changed tests: none
- left open: mapped to the existing `Auth` variant, so no new variant and no ruling needed. Nothing in core re-logs in with the saved device token on `Auth`; that is a photoscore or app follow up, not in my paths. Observation only: `map_error_code` also maps 400, 401, 403 and 404 to Auth and OtpRequired for File Station calls, where those numbers mean file operation errors. Not changed here.

### R1-9: FIXED (string guard and thumbnail) and NEEDS RULING (delete is-a-file check)
- commit: da7ffbe
- test: `guard_refuses_ambiguous_or_non_file_paths`, `guard_still_accepts_ordinary_media_files`, `delete_refuses_a_bare_recycle_folder_without_any_write`, `restore_refuses_a_comma_joined_path_without_any_write` and `recycle_thumbnail_refuses_a_path_outside_the_bin` in `core/synology-api/tests/recycle_guard_mock.rs`. Every write in them is a localhost mockito mock with `expect(0)`.
- failed before the fix: guard table `"/home/#recycle/Photos/iPhone"` accepted; bare folder delete reached the `expect(0)` Delete mock; comma restore `got Ok(())` (the move mock was reached, after I made every listing answer "empty" so only the guard stood in the way; my first version passed before the fix for the wrong reason, a 501 on an unmocked listing); thumbnail `got Ok([76, 73, 86, 69, ...])` for `/home/Photos/a.jpg`.
- passes after: whole crate 237 passed, 0 failed, 3 ignored
- changed tests: none. The existing accept cases (including `..hidden.jpg` and `dir.with.dots/`) still pass.
- what the guard now refuses: control characters, invisible formatting and direction override characters, `\`, `,`, Unicode dot and slash lookalikes, and a last segment that is not `stem.ext` (non-empty stem, 1 to 10 ASCII alphanumeric extension). Non-ASCII names such as `Ålesund/IMG 1.HEIC` stay allowed. The `path` param was already sent as a JSON array.
- NEEDS RULING: a folder NAMED like a file (`/home/#recycle/Photos/2016.09`) still passes the string guard and would reach Delete. I wrote `ensure_is_recycled_file`: before Delete it lists the parent folder (the verified `List` call) and refuses unless the entry is listed with `isdir:false`. It works, but it breaks `core_tests::empty_recently_deleted_permanently_deletes_each_path` in `core/photoscore/src/lib.rs` (`refusing to delete a.jpg: it is not listed in /home/#recycle/Photos`), whose fixture lists an empty recycle folder. That crate is not mine, so I did not commit the check. The two tests for it are committed as `#[ignore = "R1-9 NEEDS RULING..."]` (`delete_refuses_a_folder_whose_name_looks_like_a_file`, `delete_refuses_an_entry_it_cannot_find`); both failed before the check and passed with it. Options: (a) land the check and have FC change that photoscore fixture to list `a.jpg` once (mockito serves a mock short of its expected hits first, so `.expect(1)` on a "present" listing created before the "gone" listing works); also two synology-api fixtures need the same (`delete_recycle_item_sends_filestation_delete` and `delete_recycle_item_fails_closed_on_a_server_error`); (b) leave delete with the string guard only and accept the dotted folder case.
- left open: whether DSM really splits a `path` on commas is unverified (no NAS contact).

### R1-8: FIXED
- commit: 7544243
- test: `upload_skipped_for_an_existing_name_is_an_error` and `upload_with_bl_skip_false_is_success` in `core/synology-api/src/upload.rs` (unit tests, localhost mock)
- failed before the fix: `a skipped upload stored nothing, got Ok(())`
- passes after: whole crate 239 passed, 0 failed, 3 ignored
- changed tests: none
- left open: only `data.blSkip == true` is detected, the marker community clients document. The real skip response shape on this NAS is unverified, and any other per-file skip field DSM may use is not handled. Picking a unique name instead of failing (so a second edit of the same photo is kept) is a product choice left to photoscore or the app.

### R1-5: FIXED
- commit: 2cdae7a
- test: `list_recycle_photos_keeps_the_newest_deletion_past_the_file_cap` in `core/synology-api/tests/recycle_mock.rs` (folder B with 5000 old files walked first, folder A with `NEW.JPG`)
- failed before the fix: `the newest deletion must be first, got RecycleItem { recycle_path: "/home/#recycle/Photos/B/F4999.JPG", ... }`
- passes after: whole crate 240 passed, 0 failed, 3 ignored
- changed tests: none
- left open: the walk now visits the whole tree to `MAX_DEPTH` instead of stopping at 5000 files, trimming to the newest 5000 whenever it holds 10 000. The number of folders walked is still bounded only by depth and the R1-6 per-folder page cap. No "truncated" flag is surfaced, because `Vec<RecycleItem>` has no room for one and adding it is a signature change.

### R1-11: FIXED
- commit: b443f66
- test: `restore_timeout_after_failed_polls_names_the_poll_error` and `delete_timeout_after_failed_polls_names_the_poll_error` in `core/synology-api/tests/recycle_mock.rs`
- failed before the fix: `no poll ever saw the file, so do not claim it is still there: unexpected server response: restore did not complete: a.jpg is still in the recycle bin` (and the same for permanent delete)
- passes after: whole crate 242 passed, 0 failed, 3 ignored
- changed tests: none. The two existing "still in the recycle bin" tests still pass, because there the last poll did see the file.
- left open: session expiry (106, 107, 119) already aborts the loop through R1-4's mapping to `Auth`. The error stays `UnexpectedResponse`; a distinct "unconfirmed" variant would be a UniFFI change.

### R1-3b: FIXED (ruling: keep strict list_items, add a lenient crawl page function)
- commit: fc5042e
- test: list_items_page_reports_raw_count_and_skipped_id_for_an_item_without_cache_key, list_items_page_fails_naming_the_index_of_an_element_without_an_id, list_items_page_fails_when_list_is_not_an_array (core/synology-api/tests/browse_mock.rs)
- failed before the fix: new function, so falsified by mutating the decoder (raw_count from decoded count, unusable ids dropped, no-id element skipped). Observed `panicked at core/synology-api/tests/browse_mock.rs:722:5: left: 2 right: 3` and the no-id test panicked at browse_mock.rs:749. The non-array test passes under that mutation because serde rejects a non-array list before the per element loop; it pins the contract, not the new code.
- passes after: gate fmt=0 clippy=0 test=0 check=0, cargo test -p synology-api passed=245 failed=0 ignored=3
- changed tests: none. New public API: `synology_api::list_items_page(transport, sid, space, offset, limit, version, syno_token) -> Result<ItemPage, CoreError>` and `pub struct ItemPage { assets: Vec<Asset>, raw_count: u32, skipped_ids: Vec<i64> }`. Plain Rust, not a UniFFI type. The per element decode moved into a private `asset_from_value` shared with `decode_item_list`, with no behaviour change.
- left open: core/photoscore ApiPageSource must switch to it (photoscore worker). Gate started at load 63, above the brief's 40 limit.

### R1-9b: FIXED (ruling: option a, is-a-file check before permanent delete)
- commit: 8d60373
- test: delete_refuses_a_folder_whose_name_looks_like_a_file, delete_refuses_an_entry_it_cannot_find (core/synology-api/tests/recycle_guard_mock.rs, `#[ignore]` removed)
- failed before the fix: with the `ensure_is_recycled_file` call removed, `delete_refuses_an_entry_it_cannot_find` panicked at recycle_guard_mock.rs:157:5 and `delete_refuses_a_folder_whose_name_looks_like_a_file` panicked in mockito mock.rs:633 (the expect(0) Delete trap was hit)
- passes after: gate fmt=0 clippy=0 test=0 check=0, cargo test -p synology-api passed=247 failed=0 ignored=1
- changed tests: three delete fixtures in recycle_mock.rs gained one line each, `listed_once_before_delete(&mut server, "a.jpg")` (a FileStation.List mock showing a.jpg as a file with expect(1), created before the other listing mocks): delete_recycle_item_sends_filestation_delete, delete_recycle_item_fails_closed_on_a_server_error, delete_timeout_after_failed_polls_names_the_poll_error (the third was added in R1-11 after the first attempt). Assertions unchanged.
- left open: photoscore core_tests::empty_recently_deleted_permanently_deletes_each_path needs the same expect(1) listing mock before its empty listing mock; it was uncommitted in the tree when I looked and is the facade worker's.
