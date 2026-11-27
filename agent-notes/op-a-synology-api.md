# op-a-synology-api, 2026-11-27

## VF-3 upload skip flag encodings
- Test `upload::tests::upload_skip_flag_accepts_number_and_string_encodings` written first.
  `cargo test -p synology-api --lib upload_skip_flag` FAILED before the fix:
  `upload.rs:218: blSkip 1 must read as skipped`.
- Fix: `upload_was_skipped` accepts JSON true, number 1, strings "1", "true", "yes" (any case).
  Everything else (false, 0, "0", "", null, 2, "x", missing data) is not a skip. The real
  skip reply shape on this NAS is still unverified (R2-3 note); no shape was invented.
- After: fmt, clippy -D warnings clean, `cargo test -p synology-api` all green.

## VF-4 LoginData Debug redaction
- Test `auth::tests::login_data_debug_redacts_every_secret` written first. FAILED before the fix:
  `auth.rs:210: LoginData Debug leaks SECRETSID: LoginData { sid: "SECRETSID", synotoken: Some("SECRETTOKEN"), ...}`.
- Fix: removed the derived Debug, wrote one that prints `<redacted>` for sid, and
  `Some("<redacted>")`/`None` for synotoken, did and device_id (only presence is shown).
- After: fmt, clippy clean, `cargo test -p synology-api` exit 0.

## VF-5 a 119 during the restore or delete poll
- Tests `restore_poll_hit_by_an_expired_session_keeps_the_uncertain_wording` and
  `delete_poll_hit_by_an_expired_session_keeps_the_uncertain_wording` in
  `tests/session_expiry_mock.rs` (localhost mockito). Both FAILED before the fix
  (`cargo test -p synology-api --test session_expiry_mock`, exit 101):
  `session_expiry_mock.rs:160` and `:212`, message was only `synology session expired (code 119)`.
- Fix in `wait_until_gone_from_recycle`: an `Auth` error during the poll stays `Auth` (so the app
  still signs the user in) but its message now names the action and file, the cause, and says
  "it may or may not have finished". `OtpRequired` has no message field, so it is passed through
  unchanged (a 403 or 404 there is really a File Station code, see REV-F2).
- After: `cargo test -p synology-api` exit 0, 257 passed, 0 failed, 1 ignored.

## VF-2 the in-loop trim of the recycle listing
- Integration test `list_recycle_photos_in_loop_trim_keeps_the_newest_of_a_huge_folder`
  (`tests/recycle_mock.rs`, localhost mockito): one folder of 11000 files in 12 pages, oldest
  first, so the trim at 10000 fires before the newest 1000 are seen. Asserts exactly 5000 kept,
  F10999 first, F6000 last, strictly newest first, every page fetched once. Passed on the
  current code. Falsified: replaced the in-loop `keep_newest` with `items.truncate(MAX_FILES)`
  (keeps the first walked): FAILED at `recycle_mock.rs:1155`, left `"F1000.JPG"`. Restored.
- That test cannot see a mutant that deletes the trim (the final `keep_newest` gives the same
  output; only memory differs). So the trim moved into `push_bounded` and unit test
  `recycle::tests::push_bounded_trims_at_twice_the_cap_and_keeps_the_newest` pushes 15000 items.
  Falsified with `if false && ...` on the trim: FAILED at `recycle.rs:914`,
  "the buffer reached 15000 items". Restored.
- Walk cost (recorded, not redesigned): every `list_recycle_photos` call, whatever its
  offset and limit, walks the WHOLE tree to MAX_DEPTH 6. Requests per call = one GET per
  folder plus one per further 1000 entries in it (11000 files in one folder = 12 GETs).
  Sorting: one O(n log n) sort of up to 10000 items per 5000 files walked, plus a final one.
  Measured: the 11000 file mock walk took 2.9 s in a debug build on localhost with load
  average about 70 (machine shared with other workers), so the number is an upper bound for
  the local overhead only; real NAS latency per GET adds to it. The caller
  (`photoscore/src/lib.rs:1107`) passes offset and limit through, so a paged UI that asks
  for page 2 pays the full walk again.
- After: fmt, clippy clean, `cargo test -p synology-api` exit 0, 259 passed, 0 failed, 1 ignored.

## VF-12 misleading test names
- No detail beyond the TODO line existed, so I read each named file. Found and fixed:
  - `redirect_mock.rs`: `browse_get_does_not_follow_a_302_to_another_origin` calls
    `download_original`, not a browse. Renamed `download_get_does_not_follow_a_302_to_another_origin`.
  - `browse_mock.rs`: `list_items_page_with_an_undecodable_element_fails_naming_it` calls
    `list_items`, and `list_items_page` does the opposite (keeps the item as a skipped id).
    Renamed `strict_list_items_with_an_undecodable_element_fails_naming_it`; its doc said the
    crawl pages `list_items`, stale since the crawl moved to `list_items_page`. Fixed.
    `one_malformed_item_is_skipped_others_still_decode` exercises only `list_items_filtered`;
    renamed `filtered_list_skips_a_malformed_item_others_still_decode` and fixed its doc.
  - `recycle_guard_mock.rs`: `delete_refuses_a_bare_recycle_folder_without_any_write` passed for
    the wrong reason. Measured with an eprintln: the result was
    `Err(Decode { message: "envelope parse failed: EOF while parsing a value at line 1 column 0" })`,
    i.e. the unmocked parent listing (mockito 501, empty body), not the folder check. Now the
    parent listing is mocked with `iPhone` as `isdir:true` and the test asserts the
    "it is a folder" refusal. Falsified by weakening `ensure_is_recycled_file` to accept any
    entry with `isdir` reported: FAILED at `recycle_guard_mock.rs:164`, "permanent delete did not
    complete: iPhone is still in the recycle bin" (localhost only; Delete is an expect(0) mock).
    Restored.
- After: fmt, clippy clean, `cargo test -p synology-api` exit 0, 259 passed, 0 failed, 1 ignored.

## AV-11 stale list_items doc
- Doc only, no test (none needed per the AV report). The `list_items` doc said malformed elements
  are skipped; since `ee27208` the unfiltered path runs `ensure_every_item_usable` and fails the
  page. The doc now says it is strict, names `list_items_page` as what the crawl and reconcile
  use, and puts the tolerant skip on `list_items_filtered` and the display paths. Also fixed
  the two inner comments that said the crawl pages `list_items`.
- Measured: no non-test caller of `synology_api::list_items` remains (grep of photoscore,
  sync-engine and the crate's lib.rs: only the re-export and a compile check). Removing it is
  a choice left open, not done.
- After: fmt, clippy clean, `cargo test -p synology-api` exit 0, 259 passed, 0 failed, 1 ignored.
  `cargo doc` warnings seen are the pre-existing `[ids]` links in album_write.rs.
