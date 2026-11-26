# r1-synology-api review notes, 2026-11-26 17:37

Scope: `core/synology-api/` (src and tests) at HEAD of `main` (29d5f95). Stale leads re-checked first, then my own pass.
Evidence comes from a throwaway probe, `core/synology-api/tests/zz_review_r1-synology-api_probe.rs`. It used localhost mockito servers only, plus `http://127.0.0.1:1` to force network errors. I ran it with `cargo test -p synology-api --test zz_review_r1-synology-api_probe -- --nocapture --test-threads=1`: 12 passed. The file has been deleted and was never committed.

### R1-1: HTTP redirects are followed cross-origin, resending the password, sid and SynoToken
- severity: high
- confidence: high
- location: core/synology-api/src/transport.rs:156 (`build_client`, no `.redirect(Policy::none())`)
- defect: The reqwest client keeps the default redirect policy, which follows up to 10 hops. A 307 or 308 replays the POST body and custom headers to whatever host `Location` names. The leaf pin only covers the first TLS handshake, and a plain http target needs no certificate at all. reqwest strips only Authorization and Cookie on a cross-origin hop. `X-SYNO-TOKEN` is not stripped, and `_sid` and `passwd` sit in the body.
- failure scenario: Something on the path to the NAS (a reverse proxy, a captive portal, a hijacked DSM) answers 307 with `Location: http://attacker/steal`. Login sends `passwd`, the OTP and the device token there. A permanent delete sends `_sid` with the `X-SYNO-TOKEN` header there. The attacker's `{"success":true}` is then accepted as a successful delete.
- evidence: EXECUTED. Mock NAS answers 307 to a second mockito server. Output: `P2 login result ok=true`, `P2 evil login hits matched=true` (body matched `passwd=hunter2`), `P2 delete result Ok(())`, `P2 evil delete hits matched=true` (matched the `X-SYNO-TOKEN: TOK` header and the `_sid=SECRETSID` body).
- suggested fix: `.redirect(reqwest::redirect::Policy::none())` in `build_client`. Treat any 3xx as an `UnexpectedResponse`.
- suggested test: A mockito NAS returns 307 to a second server. Assert that login and permanent_delete return Err and that the second server's mock has `expect(0)`.

### R1-2: Every GET path puts the session id (and for upload, SynoToken) into error text
- severity: high
- confidence: high
- location: core/synology-api/src/browse.rs:428, recycle.rs:145, recycle.rs:662, thumbnail.rs:90, download.rs:87, upload.rs:96, discovery.rs:142, search_filter.rs:125
- defect: These paths format the reqwest error with `{e}`, and that text includes the full URL with `_sid` in the query. `upload_file` also puts `SynoToken` in the query. Only `post_form` and `post_form_text` go through `scrub_reqwest_error`, which is private. Errors become `CoreError::Network` and cross the FFI into Swift, where they are shown and logged.
- failure scenario: A Wi-Fi drop during a scroll, a thumbnail fetch or an upload. The UI or log then shows `...&_sid=<live session>`, and anyone who has the log can use that session until logout.
- evidence: EXECUTED. Every GET entry point against `http://127.0.0.1:1` leaked, for example: `P1 upload: leaks_sid=true leaks_token=true :: ...entry.cgi?_sid=SECRETSID&SynoToken=SECRETTOKEN`. The same `leaks_sid=true` result came from list_items, thumb, download, recycle_list, recycle_thumb, bin_status, facets and people. The POST control did not leak: `P1 delete_item(post): leaks_sid=false`.
- suggested fix: Make `scrub_reqwest_error` `pub(crate)` and use it (`e.without_url()`) at all eight sites. Better still, route GETs through one transport helper.
- suggested test: For each public GET function, call it against `http://127.0.0.1:1` with sid `SECRETSID` and assert that `err.to_string()` does not contain it. Today 9 of these fail.

### R1-3: Browse drops undecodable items, so the crawl stops early and the local index deletes the rest
- severity: high
- confidence: medium (the synology-api half was executed; the photoscore and sync-engine half was read)
- location: core/synology-api/src/browse.rs:640 (`decode_item_list` skips elements), consumed by core/sync-engine/src/delta.rs:65-120
- defect: `decode_item_list` silently skips any element that fails to decode or has an empty `cache_key`, so `list_items` returns fewer than `limit` items for a full server page. `reconcile` does `offset += fetched; if fetched < limit { break; }`, then `delete_assets_not_in(space, keep_ids)`. A single odd item (one whose thumbnail is still being generated, or a new type DSM adds) therefore ends the crawl, and every asset after it is removed from the local index. Every later offset is also misaligned by the number of skipped elements.
- failure scenario: A library of 20k items where item 501 has no thumbnail yet. Page 6 returns 99 of 100, the crawl stops, and 19.4k assets disappear from the grid until the next crawl, which hits the same item again. This is local only: nothing on the NAS is touched.
- evidence: EXECUTED (the half in this crate): `P8 server page 3 elements, limit 3, returned 2`. The stop and delete in delta.rs is READ-ONLY.
- suggested fix: Return the raw page length alongside the decoded assets, for example `ItemPage { assets, raw_len }`, and page on `raw_len`. Log skipped ids.
- suggested test: A sync-engine test with a fake source: page 1 has 3 raw items with one skipped, and page 2 has 2 items. Assert that all 4 valid ids survive reconcile.

### R1-4: Session expiry (106, 107, 119) is indistinguishable from any other failure
- severity: medium
- confidence: high
- location: core/synology-api/src/envelope.rs:39-49 (`map_error_code`)
- defect: Only 400, 401, 403 and 404 are mapped. 105, 106, 107 and 119 become `UnexpectedResponse("unhandled synology error code N")`, so callers cannot trigger a re-login with the saved device token. `recycle_bin_status` maps 119 to `Unknown`, and the restore and delete wait loops retry 119 until the timeout. That part fails closed, but the result is mislabelled (see R1-11).
- failure scenario: The DSM session times out overnight. Every browse, delete and restore then shows a generic "unexpected response" error until the app restarts.
- evidence: EXECUTED. `P3 map_error_code(106) = UnexpectedResponse { message: "unhandled synology error code 106" }` (107 and 119 give the same), `P3 bin_status[{"success":false,"error":{"code":119}}] = Ok(Unknown)`, `P3 list_recycle root 119 = Err(UnexpectedResponse ...)`.
- suggested fix: Add a `CoreError::SessionExpired` variant (or map these codes to `Auth`) for 106, 107 and 119. Have the wait loop abort on it, as it already does for Auth.
- suggested test: `map_error_code(119)` is `SessionExpired`. Restore, with the recycle listing returning 119, returns `SessionExpired` and not "still in the recycle bin".

### R1-5: Recycle listing caps at 5000 files in walk order, before sorting by time
- severity: medium
- confidence: high
- location: core/synology-api/src/recycle.rs:273 (`break 'walk`), sort at :281
- defect: `list_recycle_photos` stops collecting at MAX_FILES in walk order and sorts by time only afterwards. With more than 5000 files in the bin, the newest deletions can be missing from "Recently Deleted" entirely. That is exactly the safety net the user reaches for straight after a mistaken delete.
- failure scenario: Folder B in the bin holds 5000 old files and folder A holds the photo deleted a minute ago. The first page shows only old files from B, and the new photo never appears.
- evidence: EXECUTED. `P4 first item /home/#recycle/Photos/B/F0.JPG mtime 1 ; NEW present in page: false`.
- suggested fix: Keep a bounded min-heap of the newest MAX_FILES entries (or collect everything up to a much larger hard cap) and sort before truncating. Also surface a "truncated" flag.
- suggested test: The P4 fixture: assert that `items[0].filename == "NEW.JPG"`.

### R1-6: File Station paging loops are unbounded
- severity: medium
- confidence: high
- location: core/synology-api/src/recycle.rs:216 (`list_folder`), and the `folder_contains` loop at recycle.rs:441-482
- defect: Both loops continue while a page returns `LIST_PAGE_LIMIT` (1000) entries. There is no page cap, no `total` check and no MAX_FILES budget inside a folder. If DSM ignores `offset` (a version change, or a proxy that caches the response), the loop never ends. It also allocates without limit.
- failure scenario: The recycle view, or the restore precheck, hangs forever with growing memory.
- evidence: EXECUTED. With a mock that always returns 1000 entries, under a 4 s timeout: `P5 list timed_out=true result=None` and `P5 restore precheck timed_out=true`.
- suggested fix: Stop when `offset >= total` (File Station returns `total`), or when a page adds no new paths. Add a hard page cap. Make `list_folder` respect the remaining MAX_FILES budget.
- suggested test: The P5 mock with `expect_at_most(N)`. Assert that the call returns within the timeout with an Err or a truncated result.

### R1-7: download_original returns non-2xx bodies as the original file
- severity: medium
- confidence: high
- location: core/synology-api/src/download.rs:89-97
- defect: `download_original` has no `status.is_success()` check, which `thumbnail.rs` does have. `map_binary_or_error` passes through anything that is neither JSON nor HTML. So a 503 or 502 from a proxy, with a text/plain body, comes back as the photo's bytes.
- failure scenario: Duplicate-before-edit, or an export, downloads the original during a DSM restart. "Service Unavailable" is then saved as `IMG_1234.HEIC`, and if it is uploaded as the "edited copy", the copy is garbage. The original on the NAS is untouched.
- evidence: EXECUTED. `P6 download 503 text => Ok("Service Unavailable")`.
- suggested fix: Return `Network` or `UnexpectedResponse` when `!status.is_success()`, the same as thumbnail.rs.
- suggested test: A 503 text/plain mock: assert Err.

### R1-8: Upload treats a name-collision skip as success
- severity: medium
- confidence: medium (the exact DSM skip response shape has not been verified on this NAS)
- location: core/synology-api/src/upload.rs:44-101 (sends `overwrite=false`), with the decode at envelope.rs:85-106 (`decode_write_success`)
- defect: With `overwrite=false`, DSM skips an existing name and still answers `success:true`, flagging it with `blSkip`. `decode_write_success` ignores the data, so the caller believes the edited copy was uploaded. The module doc says it "fails closed" on a collision, which is not what the code does.
- failure scenario: Two edits of `IMG_1.jpg` exported to the same Edited folder. The second is silently dropped, and the user believes it is backed up on the NAS.
- evidence: EXECUTED. `P9 upload blSkip => Ok(())`.
- suggested fix: Parse `data.blSkip` (and the per-file skip fields). Return a `Conflict` error, or pick a unique name before uploading.
- suggested test: A `{"success":true,"data":{"blSkip":true}}` mock: assert Err.

### R1-9: Recycle path guard accepts directories and some non-canonical paths
- severity: medium
- confidence: medium
- location: core/synology-api/src/recycle.rs:328-343 (`ensure_recycle_photos_path`)
- defect: The guard checks the prefix and rejects `.`, `..` and empty segments. It accepts the following:
  - A bare folder inside the bin, which makes `delete_recycle_item` permanently delete a whole recycle subtree.
  - Backslash and full-width-dot segments.
  - Embedded newlines.
  - A comma-joined list. File Station's `path` parameter accepts comma-separated multiple paths in some versions, so `a.jpg,/home/Photos/b.jpg` might reach a live original.

  It is also not applied to `recycle_thumbnail`. That function is read-only, but it lets a caller fetch an arbitrary path.
- failure scenario: A UI or FFI bug passes `/home/#recycle/Photos/iPhone`, and every file under it is destroyed with no further confirmation. Separately, a filename containing a comma becomes a two-path delete if DSM splits on commas (unverified).
- evidence: EXECUTED. `P10 guard "/home/#recycle/Photos/iPhone" => ok=true`, `P11 delete whole recycle subfolder => Ok(()), delete sent=true`, and `ok=true` for the backslash, full-width dot, newline and comma variants. Rejected correctly: NUL, lowercase `photos`, `PhotosEvil`, trailing slash, leading `//`. Whether DSM honours a comma list is unverified (no NAS contact allowed).
- suggested fix: Reject control characters, `\`, `,` and non-ASCII dot lookalikes. Send `path` as a JSON array (`["..."]`) so a comma cannot split it. Have delete refuse paths that File Station reports as `isdir`, or require a file extension. Apply the guard in `recycle_thumbnail`.
- suggested test: The P10 table as asserted `is_err()` cases, plus a delete mock with `expect(0)` for a directory path.

### R1-10: pin_version panics when a capability reports min > max
- severity: low
- confidence: high
- location: core/synology-api/src/info.rs:106 (`desired.clamp(cap.min_version, cap.max_version)`)
- defect: `u32::clamp` panics if min > max. That data comes straight from the NAS's `SYNO.API.Info` response, and a panic across UniFFI aborts the Mac app.
- failure scenario: A quirky DSM build, or a hostile host, reports `minVersion:3, maxVersion:2`, and the app crashes at login.
- evidence: EXECUTED. `panicked at core/synology-api/src/info.rs:106:16`, and `P7 pin_version min>max panicked=true`.
- suggested fix: Treat min > max as unsupported and return None, or use `min(max).max(min)` ordering without clamp.
- suggested test: `pin_version` with min 3 and max 2 does not panic and returns None.

### R1-11: Restore and delete timeouts report "still in the recycle bin" whatever the real cause
- severity: low
- confidence: high
- location: core/synology-api/src/recycle.rs:488-511 (`wait_until_gone_from_recycle`)
- defect: The loop is bounded and fails closed, which is good. But every non-auth error (119, network, decode) is retried silently, and the final error claims the file is still there. That hides the real cause and may lead the user to retry a restore that did in fact complete.
- failure scenario: The session expires mid-restore. The user sees "restore did not complete: a.jpg is still in the recycle bin" even though the move may have succeeded.
- evidence: EXECUTED. With the recycle listing returning 119 on every poll: `P12 restore with 119 polls => Err(UnexpectedResponse { message: "restore did not complete: a.jpg is still in the recycle bin" })`.
- suggested fix: Remember the last poll error and include it in the timeout message. Abort on the session-expiry codes from R1-4.
- suggested test: The P12 fixture: assert that the message mentions 119 or session expiry.

### R1-12: Most mock tests do not assert the session or the parameters actually sent
- severity: low
- confidence: high
- location: core/synology-api/tests/browse_mock.rs (13 mocks with `Matcher::Any`), search_mock.rs, filter_items_mock.rs, thumbnail_mock.rs:107/167, download_mock.rs:69/111/131, info_mock.rs
- defect: Only album_write_mock, download_mock (one test), auth_mock (logout) and recycle_mock assert that `_sid` is sent. Most browse, search and filter tests match `Matcher::Any`, so dropping `_sid`, `offset`, `limit` or `additional=["thumbnail",...]` (whose absence on the real NAS loses `cache_key`) would still pass. The recycle write tests are good: they pin api, method, version, path, overwrite and remove_src, plus `expect(0)` traps.
- failure scenario: A refactor drops `additional` from the browse query. All mock tests stay green, and on the real NAS every item lacks `cache_key`, so R1-3 then empties the grid.
- evidence: EXECUTED. `grep -c '"_sid"' tests/*.rs` gives a non-zero count only in download_mock (1) and recycle_mock (1), plus Regex `_sid=` in album_write_mock and auth_mock. `grep -n "Matcher::Any"` gives 28 query or body wildcards.
- suggested fix: Have each list test match `_sid`, `offset`, `limit` and `additional`.
- suggested test: Not applicable (this is the test fix).

## Checked and clean
- Stale `Session` Debug leak: fixed by 772f6ed (manual redacting Debug). Dropped.
- Stale R1-3 (delete or restore on an arbitrary path): fixed by dce9c23 (`ensure_recycle_photos_path` in both write paths). The residual gaps are in R1-9.
- Stale R1-4, the empty-bin part (every error read as an empty bin): fixed by bd5cdc2. Only 408 at the root means empty, and subfolders skip only 407 and 408. The session-code part continues as R1-4.
- Stale R1-7 (restore or delete reported done before the task finished): mitigated by d7d5cef. The wait-until-gone polling is bounded (`attempts.max(1)`, default 80 × 250 ms) and fails closed. The residual is R1-11.
- `recycle_bin_status` never maps to Enabled on error. 119, 106, `success:true` with no data, `"true"` as a string, `1`, null data, an HTML body, an empty body and HTTP 500 all gave `Ok(Unknown)`, and Auth, OtpRequired and Network propagate (EXECUTED, P3).
- Guard rejects the following (EXECUTED, P10): `..`, `//`, a leading `//`, a trailing slash, an empty path, the `PhotosEvil` prefix, lowercase `photos`, and NUL. Percent-encoded `%2e%2e` passes the guard, but reqwest re-encodes `%` to `%25`, so DSM sees a literal name. That is safe unless DSM double-decodes (unverified).
- Restore name-clash race: there is a check-then-act gap between `folder_contains` and CopyMove, but CopyMove uses `overwrite=false`, so a racing file causes a skip. The source then stays in the bin, and the wait loop fails closed. No overwrite of an original. Whether DSM still removes the source when `remove_src=true` and the copy was skipped is unverified against a real NAS.
- TLS pinning: the pin takes precedence over `allow_untrusted_tls`, it is an exact leaf DER match with signature verification through ring, and bad DER is rejected. The weakness on a redirect is R1-1, not the verifier.
- POST paths (`post_form`, `post_form_text`) scrub the URL from errors (EXECUTED, P1 control).
- `map_binary_or_error`: an HTML error page and a JSON `success:false` are both treated as errors for thumbnails. Download has the status gap in R1-7.
- `success:false` with an unknown code never decodes as success in `decode_write_success`.
- album_write and delete_item (`permanent_delete`, Browse.Item v7, id array): the parameters are correctly encoded and the tests assert api, method, id and version. A stale module doc in delete_item.rs describes an app-album move (doc only).
- Query encoding: reqwest `.query()` and form encoding are used everywhere, with no hand-built query strings except the upload URL, which uses only sid and token.
- The pre-existing tests are not in scope for a skip check: `real_nas_ignored.rs` is the single ignored test and is correctly marked `#[ignore]`.
