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
