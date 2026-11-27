# op-b-photoscore, 2026-11-27

Owned: core/photoscore/, core/persistence/src/account.rs. Every test runs
against in-memory or temp dir stores and localhost mockito. Nothing reached
the NAS or any other host.

## VF-6 (917e381)
- Added `a_delete_during_a_sync_is_applied_when_run_with_store_returns`. The
  work closure parks on a oneshot while the store is out, the test runs a real
  `delete_assets`, then releases the sync.
- Mutant: `self.return_store(store)` in `run_with_store` replaced with a plain
  put back. Failed at the fetch assertion: `left: [2, 1] right: [2]`.
  Restored: 79 passed, exit 0.

## VF-7 (a45923c)
- Added `first_bind_clears_an_index_holding_any_single_kind_of_row`, one case
  per branch of `index_has_rows` (assets, albums, app_state, and each of the
  six sync_state columns written alone).
- Ten mutants, each dropping one branch (or the whole sync_state clause):
  every one failed the new test only, the other five account tests passed,
  so all ten survived before. Example failure: "an unowned index holding only
  an album must be cleared". persistence: 77 passed, clippy exit 0.

## VF-8 (6b73f6e)
- Split `reconcile_delta` into `reconcile_with_source` (private, same as
  `crawl_with_source`), added
  `a_reconcile_from_the_previous_account_writes_nothing_after_a_sign_in`.
- Mutant: pass the store's bound identity instead of `source.account`. Failed:
  `got Err(UnexpectedResponse { "The NAS listed no items, so none of the 1
  local items were removed." })`, so alice's list page was read. Restored: pass.

## VF-9 (204c770)
- Rewrote the `save_edited_photo` doc: it said FAIL CLOSED on either step,
  the re-index is now best effort. Doc only, no test.
- Not in my paths: `platforms/macos/Generated/PhotosCore.swift` lines 931 and
  1885 still carry the old text until the bindings are regenerated. The
  `1016098` half of VF-9 is Swift, not mine.

## AV-7 (3478f2b)
- `sign_out` clears `pending_local_deletes`; `bind_index_to_account` clears it
  on a reset while still holding the store guard. Originals moved from the
  system temp dir to `<cache_dir>/originals`, emptied with `thumbs` on sign
  out and on an account switch (`clear_account_caches`).
- Tests seen failing first: `sign_out_drops_queued_local_deletes_...`
  (assert `is_empty` at sign out), `an_account_switch_drops_queued_local_deletes`
  ("a reset index takes the old account's queue with it"),
  `sign_out_removes_downloaded_originals` (file still at
  `/tmp/claude-501/syno-orig-...`). Extra mutant with the is_empty assert and
  both clears removed: bob's row dropped, `left: 0 right: 1`.
- Open, not my paths: the Swift side may hold its own original image cache;
  not checked.

## AV-8 (d328c44)
- A failing local removal after a successful NAS delete now logs, queues the
  ids and returns Ok.
- Test `delete_assets_reports_success_when_only_the_local_removal_fails` uses
  `/usr/bin/sqlite3` (falls back to `sqlite3` on PATH) to add a trigger that
  aborts every delete on `assets` in the test's own temp db, then drops it.
  Failed first: `Storage { message: "simulated storage failure" }`. After fix:
  84 passed, exit 0.
- Note: a queued removal is applied only when a sync hands the store back,
  not on the next direct call; the next reconcile also drops the rows.

## Final
- `cargo test -p photoscore`: 84 passed, 0 failed, 0 ignored (lib) plus 1
  integration test. `cargo clippy -p photoscore --all-targets -- -D warnings`:
  exit 0. persistence: 77 passed.
