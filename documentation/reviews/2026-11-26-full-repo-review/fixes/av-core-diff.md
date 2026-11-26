# AV core diff: adversarial review of the core fixes (1c2c107..HEAD, core/)

Date: 2026-11-26. Reviewer label: av-core-diff. Read only on the real tree. Every execution ran in a scratch copy under `$TMPDIR/avcore` (core, root Cargo.toml, Cargo.lock, rust-toolchain.toml) with `CARGO_TARGET_DIR` inside it. No network host was contacted; the tests used only their own localhost mocks.

## Findings (most severe first)

### AV-1: A comma, or a file with no extension, makes an item impossible to restore, and one such item refuses the whole Restore or Empty batch
- severity: high (recovery path for invariant 2; the user cannot get a deleted original back through the app before DSM retention purges it)
- confidence: high
- location: core/synology-api/src/recycle.rs:440 (`is_refused_path_char` refuses `,`), core/synology-api/src/recycle.rs:416 (extension rule), core/photoscore/src/lib.rs:1138 (restore and empty pre check every path before the first operation)
- introduced by: da7ffbe (Tighten the recycle path guard)
- defect: `ensure_recycle_photos_path` refuses any path containing a comma and any last segment without a 1 to 10 character ASCII alphanumeric extension. Commas are common in real folder names ("Paris, France", "Smith, John"). The `path` parameter is always sent as a JSON array through `json_path_array`, so a comma is not ambiguous there and the refusal buys no safety for it. Files with no extension or a non ASCII extension are legal in Synology Photos. `restore_recently_deleted` and `empty_recently_deleted` validate EVERY path up front, so a single refused item blocks the entire selection. The error text also says "outside" the root, which is false and misleading.
- failure scenario: the user deletes a folder of trip photos stored under "Photos/Paris, France/". All of them land in the recycle bin. Restore refuses every one ("refusing a path outside /home/#recycle/Photos"). Selecting all of Recently Deleted to restore fails entirely because one of the items is in that folder. The user has to use DSM File Station by hand, or loses the files once retention expires.
- evidence: EXECUTED. A scratch only test in `$TMPDIR/avcore/core/synology-api/src/recycle.rs` called `ensure_recycle_photos_path`; `cargo test -p synology-api --lib av_probe -- --nocapture` printed:
  `/home/#recycle/Photos/Paris, France/IMG_1.jpg => Err(UnexpectedResponse { message: "refusing a path outside /home/#recycle/Photos: ..." })`
  `/home/#recycle/Photos/2024/IMG_1 => Err(UnexpectedResponse ...)`
  `/home/#recycle/Photos/2024/IMG_1.jpg => Ok(())`
- suggested fix: drop `,` from the refused set for paths that only travel JSON encoded. If `dest_folder_path` (plain) is the reason, encode or validate that parameter on its own. Allow extensionless files for Restore (Restore cannot destroy anything); keep the file check for Delete through `ensure_is_recycled_file`, which already asks File Station whether the entry is a file. Validate per item and report the refused items instead of refusing the batch. Fix the "outside" wording.
- suggested test: restore of `/home/#recycle/Photos/Paris, France/IMG_1.jpg` against the File Station mock sends the CopyMove with the JSON encoded path; a batch of one good and one refused path restores the good one and reports the other.

### AV-2: File Station error codes 400, 401, 403 and 404 are mapped to Auth and OtpRequired, so a recycle bin failure signs the user out or asks for an OTP
- severity: medium
- confidence: high on the mapping, medium on the UI effect
- location: core/synology-api/src/envelope.rs:39 (`map_error_code`), used by the recycle decode; core/synology-api/src/recycle.rs:218 (`dsm_error_code` only surfaces codes that map to UnexpectedResponse)
- introduced by: pre-existing, not fixed by e942def (which added 106, 107 and 119 to the same global table)
- defect: the table is the SYNO.API.Auth table and is applied to every API, including SYNO.FileStation.*, where 400 means invalid parameter, 401 unknown error, 403 invalid user, 404 invalid group. `with_partial_progress` (1572682) then deliberately keeps the Auth variant so "the UI sends the user to sign in".
- failure scenario: restoring an item whose name DSM rejects returns File Station 400; the app treats it as an auth failure ("Sign in failed. ...") and may route to the login screen. A 403 shows "Enter your two-factor code to continue" for a recycle error. The real cause is hidden.
- evidence: EXECUTED. Scratch only probe in `$TMPDIR/avcore/core/synology-api/src/envelope.rs`, `cargo test -p synology-api --lib av_probe_codes -- --nocapture`: `400 => Auth`, `401 => Auth`, `403 => OtpRequired`, `404 => OtpRequired`, `408 => UnexpectedResponse`. That the recycle path reaches this table is READ ONLY.
- suggested fix: give File Station replies their own code table (400 to 599 as UnexpectedResponse or a Dsm variant with the code; only 105, 106, 107, 119 as Auth), selected by the caller rather than globally.
- suggested test: a File Station mock returning `{"success":false,"error":{"code":400}}` to a restore must not yield `CoreError::Auth` or `OtpRequired`.

### AV-3: The recycle bin safety check reads the HOME recycle bin even for a Shared space delete
- severity: medium (latent; Shared space is not enabled on this NAS, error 801)
- confidence: medium
- location: core/photoscore/src/lib.rs:1065
- introduced by: 8ab1b83 (incomplete)
- defect: `delete_assets` calls `recycle_bin_status` (SYNO.Core.User.Home, the home recycle bin) for both spaces. Shared space originals live in the `/photo` shared folder, whose recycle bin is a separate per share setting. A Shared delete can be permanent while the check passes.
- failure scenario: once Shared space is enabled, the admin has the home recycle bin on and the `photo` share recycle bin off. Deleting a shared photo passes the guard and is permanent, breaking invariant 2.
- evidence: READ ONLY.
- suggested fix: for `Space::Shared` either refuse delete until the share's recycle bin status can be read (SYNO.Core.Share get `enable_recycle_bin` for `photo`), or treat it as Unknown and warn.
- suggested test: a Shared delete with the home bin enabled and the share bin disabled must be refused before the delete verb is sent.

### AV-4: login spends the OTP and the DSM session before it finds the store busy
- severity: medium
- confidence: high
- location: core/photoscore/src/lib.rs:229 (bind after `synology_api::login`), core/photoscore/src/lib.rs:1520 (`ok_or_else(store_busy_err)`); same in restore_session at core/photoscore/src/lib.rs:297
- introduced by: 5945810
- defect: `bind_index_to_account` fails closed with "store busy" while a crawl or reconcile holds the store. `login` calls it only after the network login succeeded, so the one time code is consumed, a server session is left open (no logout on that path), and the user sees "Local storage problem. store busy". The account identity is only known from transport plus username, which are available before the network call.
- failure scenario: the user signs out while a long initial crawl is running (the crawl keeps the store until it finishes or errors), then signs back in with an OTP. Login fails with a storage error, the OTP is gone, and they must wait for a new one and retry until the crawl ends. restore_session on launch can hit the same window and lands in `.invalid` (Storage is not retryable in Swift), discarding a valid stored session.
- evidence: READ ONLY (ordering at lines 220 to 229).
- suggested fix: check the store is present (and compare identity) BEFORE the network login, or on store busy log out the fresh session best effort and return a retryable error; sign_out should cancel or wait for a running crawl.
- suggested test: hold the store out (as the busy delete test does), call login against the mock; assert the error and that the mock saw either no auth call or a logout.

### AV-5: The account identity includes the host string, so switching between LAN IP and Tailscale name wipes the index each time
- severity: medium (data is rebuildable, but a full recrawl of 20k to 100k items plus all thumbnails on every switch)
- confidence: high
- location: core/photoscore/src/lib.rs:1358 (`account_identity` uses `transport.base_url()`), core/persistence/src/account.rs:45
- introduced by: 5945810
- defect: the identity is `base_url|username`. The project supports LAN and Tailscale (direct IP or MagicDNS) as equal paths, so the same NAS and user produce different identities (`https://192.168.x.y:5001|u` versus `https://fafnir....ts.net:5001|u`). Each switch clears assets, albums, app_state, sync_state and the thumbs dir. Conversely, two different NASes reached at the same LAN IP on different networks share one identity and the second sees the first's rows.
- failure scenario: a laptop used at home on the LAN address and away on the Tailscale name re-imports the whole library every time it changes network profile.
- evidence: READ ONLY.
- suggested fix: bind to a NAS specific id (DSM serial or `SYNO.Core.System` info, or the pinned certificate fingerprint) plus the DSM uid, not the URL.
- suggested test: bind with two base URLs that report the same server id must not reset.

### AV-6: The sweep confirmation never converges under churn and confirms a stable truncation on the second refresh
- severity: medium to low
- confidence: medium
- location: core/sync-engine/src/delta.rs:200 to 224 (`sweep_is_plausible`)
- introduced by: 05240b6
- defect: a large drop is accepted only if two consecutive listings have the identical keep set fingerprint. With a phone backing up continuously (new ids every few minutes) or a flapping skipped id, the fingerprint differs on every run, so a real mass deletion done in the web app leaves ghost rows in the grid indefinitely with a repeating refusal. The opposite case: a deterministic, stable short listing (a NAS mid re index that returns the same truncated set twice) passes the guard on the second Refresh and deletes up to 80 percent of the local index (local only, rebuildable, but a crawl is needed).
- evidence: READ ONLY for the failure modes. EXECUTED for the guard itself (see Checked and clean).
- suggested fix: confirm on the stale set (the ids to delete) being a subset of the previous refusal's stale set, rather than on the exact keep set; and require the server `total` to agree with the listed count before accepting.
- suggested test: two reconciles with the same deletions but one added new id each time must apply the deletion on the second run.

### AV-7: sign_out leaves the queued local deletes and the original image cache behind
- severity: low
- confidence: medium
- location: core/photoscore/src/lib.rs:320 (`sign_out`), core/photoscore/src/lib.rs:173 (`pending_local_deletes`)
- introduced by: 1974d3f and 5945810 together
- defect: `sign_out` removes only `cache_dir/thumbs`. `pending_local_deletes` (ids from account A) survives and is applied by `return_store` to whatever account's index is present next; ids are per NAS, so on a different account it can drop unrelated rows (local only, healed by the next reconcile unless AV-6 refuses). Downloaded originals in the cache stay on disk after signing out.
- evidence: READ ONLY.
- suggested fix: clear `pending_local_deletes` in `sign_out` and in `bind_index_to_account` when it resets; tag each entry with the account identity and skip mismatches; clear the originals cache on sign out.
- suggested test: queue a delete while the store is out, sign out, bind another account, return the store; the new account's rows must be untouched.

### AV-8: A failing local removal after a confirmed NAS delete reports the delete as failed
- severity: low
- confidence: medium
- location: core/photoscore/src/lib.rs:1088 (`store.delete_assets(space, &ids)?`)
- introduced by: pre-existing, not fixed by 1974d3f (which handled only the busy case)
- defect: when the NAS delete succeeded but the SQLite delete errors (disk full, locked), the error reaches the UI as a failed delete although the originals are already in the recycle bin. A retry then fails on the server (ids gone) and the rows stay until a reconcile.
- suggested fix: on local error, queue the ids like the busy branch and return Ok, logging the storage error.
- suggested test: a store that fails `delete_assets` after a successful mock delete returns Ok and the ids are queued.
- evidence: READ ONLY.

### AV-9: A server that ignores offset makes crawl and reconcile loop forever
- severity: low
- confidence: medium
- location: core/sync-engine/src/delta.rs (paging loop, `offset += raw_count`), core/sync-engine/src/crawl.rs (same)
- introduced by: pre-existing, not fixed by ee27208 or baea50e (the PageGuard was added only to File Station)
- defect: if every page returns a full `raw_count` of the same items, the loop never terminates and the store stays taken, which then makes login, restore_session and delete queueing hit AV-4 indefinitely.
- evidence: READ ONLY.
- suggested fix: reuse the recycle `PageGuard` idea (stop when a page repeats its first and last ids, or when offset exceeds a multiple of the reported total).
- suggested test: a mock that returns the same full page for any offset must end with an error within a bounded number of calls.

### AV-10: date_histogram fails as a whole on an extreme taken_at
- severity: low
- confidence: medium
- location: core/persistence/src/assets.rs:488
- introduced by: pre-existing, not fixed by 80d4210
- defect: `taken_at - (((taken_at % 86400) + 86400) % 86400)` overflows for taken_at within 86400 of i64::MIN; SQLite then yields a REAL and `r.get::<_, i64>` fails, so the grid gets no sections at all for one corrupt EXIF value. The i64::MIN unknown date key itself is safe (it is never added to, and Swift compares it with `Int64.min`).
- evidence: READ ONLY.
- suggested fix: clamp or filter taken_at to a sane range (for example year 1800 to 3000) in the SELECT, routing the rest to the unknown date bucket.
- suggested test: insert taken_at = i64::MIN + 1 and assert the histogram returns it in the unknown bucket.

### AV-11: The list_items doc says malformed elements are tolerated, but the unfiltered path is now strict
- severity: low (doc only; the app routes through list_page)
- confidence: high
- location: core/synology-api/src/browse.rs:453 and the strict `ensure_every_item_usable` in `list_items_inner`
- introduced by: ee27208
- evidence: READ ONLY.
- suggested fix: update the doc, or remove the strict unfiltered variant now that only tests use it.
- suggested test: none needed beyond the doc.

## Checked and clean
- Recycle bin Disabled refusal in delete_assets (8ab1b83): EXECUTED. Replaced the check with `if false && ...` in scratch; `cargo test -p photoscore --lib delete_assets_refuses_when_the_recycle_bin_is_disabled` FAILED ("a delete with the recycle bin off must be refused: ()"), passes with the fix.
- Sweep guard large drop (05240b6): EXECUTED. With `large_drop = false` in scratch, `listing_over_the_threshold_is_refused_until_repeated` and `a_different_short_listing_does_not_confirm_the_first` FAILED, 12 others passed.
- Sweep guard empty listing (05240b6): EXECUTED. With the empty keep check disabled, `empty_listing_keeps_every_local_row` FAILED.
- Busy store queue (1974d3f): EXECUTED. Replacing `.push((space, ids))` with `.clear()` made `delete_assets_while_the_store_is_busy_queues_the_local_removal` FAIL at lib.rs:3821.
- Bulk delete in persistence (`delete_assets_not_in` temp table, `delete_assets` 500 id chunks): READ, single transaction with rollback, temp table cleared, correct.
- return_store drains the queue under the store guard, so no removal can be queued after the drain: READ, correct.
- bind_account clears app_state including the sweep fingerprint, so no stale fingerprint crosses accounts: READ.
- Refused sweep keeps upserts and leaves reconcile_at unset; the watermark does not gate the reconcile listing, so nothing is skipped forever: READ.
- Paging on raw_count with skipped_ids counted as present (ee27208): READ, consistent in crawl and reconcile.
- run_with_store refuses a store bound to another account (07c86b4): READ.
- Redirects refused in build_client and URL stripped through `network_error` / `without_url` at every reqwest send and body read site (27f3457): READ, every call site in synology-api uses it, no `{e}` on a reqwest error remains.
- Non 2xx download (9e70dec): READ, a non 2xx body never returns as file bytes; a JSON envelope keeps its mapping.
- Upload blSkip (7544243): READ, a skipped upload is an error and the edit save does not report success.
- with_partial_progress (1572682): READ, keeps the variant and adds the count; see AV-2 for why keeping Auth is harmful with the current table.
- JSON path encoding of File Station `path`: READ, serde_json array, correct.
- i64::MIN unknown date key: READ, never arithmetically used, Swift matches it with `Int64.min`.
