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
