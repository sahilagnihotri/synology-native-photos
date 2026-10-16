
---
## clippy worker (2026-10-16)
- Repo override toolchain 1.97.1 has no clippy component. `cargo +stable clippy` (0.1.99) works.
- Measured before, `cargo +stable clippy -p synology-api -p sync-engine --all-targets`: 45 warnings in the two crates (33 fn item to integer casts in lib.rs facade test, 4 to_vec + 1 to_string in tests, 5 too_many_arguments, 1 sort_by_key, 1 double_must_use from async_trait). Plus 1 in `persistence` (assets.rs:351 too_many_arguments), not owned, left alone. TODO's "63" is stale.
- After: 0 in the two crates. `cargo test -p synology-api -p sync-engine` all green (no failures).
- too_many_arguments on browse/thumbnail fns is allowed with a comment: they mirror flat DSM params and are called from the FFI facade owned by other workers.

---
## clippy worker, persistence/models (2026-10-16)
- Added `components = ["clippy", "rustfmt"]` to rust-toolchain.toml. Bare `cargo clippy` could NOT be confirmed: rustup needs to write ~/.rustup/tmp to install the component and the sandbox returns "Operation not permitted". Needs one unsandboxed run by Sahil: `rustup component add clippy rustfmt` (or any cargo command in the repo).
- Measured with `cargo +stable clippy -p persistence -p models --all-targets`: before 5 warnings (1 too_many_arguments on filter_assets, 4 identity_op `1 *` in assets.rs tests), models 0. After 0. Tests: persistence 23+65 passed, 0 failed.
- filter_assets keeps an allow: signature is used by photoscore, which another worker owns.

---
## clippy worker, trash leftovers (2026-10-16)
- Grep over core/ app/ bindings/ found no callers of fetch_trash, trash_count, set_trash_flag, all_in_trash outside persistence itself, and no callers of synology-api add_items, remove_items, create_album outside their own tests and the lib.rs re-export. Removed all seven plus their tests. delete_album kept (not in scope).
- New persistence migration step 5 `UPDATE assets SET in_trash = 0, trashed_at = NULL` (columns and index kept). Test `v4_to_v5_migration_unhides_legacy_trashed_rows`. Falsified: with the UPDATE neutralised the test FAILED ("legacy trashed row must be visible again", left: []); restored, 61 persistence tests pass.
- v2_to_v3 trash-preservation test now calls the v3 step directly, since a full run_migrations now ends in step 5 which clears flags by design.
- Tests that pin "upsert preserves in_trash" remain and use a test-only SQL helper. Crawl upserts still never reset the flag: harmless now that nothing sets it.
- Results: persistence 61 passed, synology-api all suites passed, clippy clean for both, workspace cargo check clean.
