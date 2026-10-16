
---
## rust-redact worker, 2026-10-16 (context: R5.1)
Measured:
- Only `Session` held secrets with derived Debug (sid, syno_token, device_did). `Connection` holds a pinned cert (public) and no credentials; no other model type holds a password, OTP or token.
- `cargo test -p models`: 23 passed with the manual impl (22 before, plus `session_debug_redacts_secrets`).
- Falsification: with `#[derive(Debug)]` restored, the test FAILED (22 passed, 1 failed); with the manual impl restored, 23 passed.
- `cargo build --workspace` ok. `cargo test --workspace` all suites ok, 0 failed.
