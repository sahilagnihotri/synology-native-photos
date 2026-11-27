# tasks.md — dispatch state

Live dispatch only. `TODO.md` says what needs doing; this file says who owns what right now.
Status: queued, in-progress, awaiting-verification, verified, abandoned.

## CURRENT (2026-11-26): full-repo review, fixes, Windows core check

Baseline at `1c2c107` (2026-11-26, this Mac now on macOS 27.0 and Xcode 27.2):
`scripts/ci/ci.sh core` PASS at baseline (fmt, clippy, Rust 385 passed, 0 failed, 1 ignored,
2 script tests). The Swift stage could not build until `a911257`; after it the
Xcode test run passes with 498 tests, 0 failed, 0 skipped.

The review and the five fix batches are finished and verified by the
orchestrator (see `Fixed.md`), and the adversarial pass is done (open items: AV-2026-11 in `TODO.md`). Remaining:

| ID | Goal | Owned paths (write) | Status | Closes |
|----|------|---------------------|--------|--------|
| VF | Verify every fix since `1c2c107` by falsification, in throwaway clones under `$TMPDIR` (workflow `wf_1b96ff9c-4d7`, read only on this tree) | none in this tree | verified (2026-11-27): gates re-run by the orchestrator, defects fixed in `78772e6`, `515dbd4`, `2ad2460`, `5d56183` | VF-1 to VF-12 opened in `TODO.md` |
| W1 | Windows: PowerShell scripts still unexecuted | `scripts/windows/`, `scripts/ci/ci.ps1` | blocked on the user (see WIN-1) | WIN-1 |

Blocked on the user: DSM password change, `photosclient` user, a test album for album verification.
