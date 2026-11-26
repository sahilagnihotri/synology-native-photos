# tasks.md — dispatch state

Live dispatch only. `TODO.md` says what needs doing; this file says who owns what right now.
Status: queued, in-progress, awaiting-verification, verified, abandoned.

## CURRENT (2026-11-26): full-repo review, fixes, Windows core check

Baseline at `1c2c107` (2026-11-26, this Mac now on macOS 27.0 and Xcode 27.2):
`scripts/ci/ci.sh core` PASS at baseline (fmt, clippy, Rust 385 passed, 0 failed, 1 ignored,
2 script tests). The Swift stage could not build until `a911257`; after it the
Xcode test run passes with 498 tests, 0 failed, 0 skipped.

The review and the five fix batches are finished and verified by the
orchestrator (see `Fixed.md`). In flight:

| ID | Goal | Owned paths (write) | Status | Closes |
|----|------|---------------------|--------|--------|
| AV | Adversarial review of the core fix commits (`git diff 1c2c107..HEAD -- core/`), read only | `agent-notes/av-core-diff.md` | in-progress | project rule for delete and sync changes |
| W1 | Windows: PowerShell scripts still unexecuted | `scripts/windows/`, `scripts/ci/ci.ps1` | blocked on the user (see WIN-1) | WIN-1 |

Blocked on the user: DSM password change, `photosclient` user, a test album for album verification.
