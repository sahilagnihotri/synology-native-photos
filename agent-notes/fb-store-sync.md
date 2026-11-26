# FB fix notes: persistence, sync-engine, models

### R3-1 (and R2-1): FIXED
- commit: c4319c2
- test: `delete_assets_not_in_handles_a_keep_set_above_the_variable_limit` and `delete_assets_handles_a_delete_set_above_the_variable_limit` in core/persistence/src/assets.rs (40,000 Personal rows plus one Shared row; exact survivor sets asserted)
- failed before the fix: `called Result::unwrap() on an Err value: Storage { message: "variable number must be between ?1 and ?32766 in DELETE FROM assets WHERE space = ?1 AND server_id NOT IN (?2,?3,...` (and the same for `server_id IN (...)`)
- passes after: `cargo test -p persistence`: `test result: ok. 63 passed; 0 failed; 0 ignored`; `cargo test -p sync-engine`: `ok. 17 passed; 0 failed; 0 ignored`
- changed tests: none
- left open: none. The keep set goes into `temp.reconcile_keep` and one `NOT IN (SELECT ...)` anti-join; `delete_assets` binds in chunks of 500 in one transaction. The error text can no longer carry a 32k placeholder string because no statement is that large any more.
