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
