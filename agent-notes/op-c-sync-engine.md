
## op-c-sync-engine 2026-11-27

AV-9: added `PageGuard` in core/sync-engine/src/lib.rs. A page whose non-empty id list (decoded plus skipped) equals the previous page's is a repeat, and crawl and reconcile now fail with UnexpectedResponse ("ignore offset"). Tests `crawl_fails_when_the_server_ignores_offset` and `reconcile_fails_when_the_server_ignores_offset` use an in-memory source that panics after 50 calls.
Measured: before the guard was wired, both tests FAILED with "paging never stopped" (crawl.rs:649). After: `cargo test -p sync-engine` 29 passed, 0 failed; clippy -D warnings clean. Both tests assert exactly 2 source calls.
Limit: a repeated page of zero ids (all undecodable, none named) is not detected.
