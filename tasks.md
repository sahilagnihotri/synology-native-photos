# tasks.md — dispatch state

Live dispatch only. `TODO.md` says what needs doing; this file says who owns what right now.
Status: queued, in-progress, awaiting-verification, verified, abandoned.

## CURRENT (2026-11-26): full-repo review, fixes, Windows core check

Baseline at `1c2c107` (2026-11-26, this Mac now on macOS 27.0 and Xcode 27.2):
`scripts/ci/ci.sh core` PASS (fmt, clippy, Rust 385 passed, 0 failed, 1 ignored,
2 script tests). The Swift stage could not build until `a911257`; after it the
Xcode test run passes with 498 tests, 0 failed, 0 skipped.

The review is finished (reports in `documentation/reviews/2026-11-26-full-repo-review/`).
Fix workers below. One finding is one commit with a test that failed before the
fix. Each worker appends to `agent-notes/<label>.md`. Queues are in order.

| ID | Goal and queue | Owned paths (write) | Status | Closes |
|----|----------------|---------------------|--------|--------|
| FA | DSM client fixes: R1-1, R1-2, R1-7, R1-10, R1-3, R1-6, R1-4, R1-9, R1-8, R1-5, R1-11 | `core/synology-api/`, `agent-notes/fa-synology-api.md` | in-progress | those IDs |
| FB | Index and reconcile fixes: R3-1 (same as R2-1), R2-4 (same as R3-4), R3-3, R3-6, R3-7, R3-2, R3-5 | `core/persistence/`, `core/sync-engine/`, `core/models/`, `agent-notes/fb-store-sync.md` | verified by the orchestrator: persistence 70/0/0, sync-engine 22/0/0, models 23/0/0. Ruling R2-4: option (a) for now, see TODO | those IDs |
| FC | Facade fixes: R2-2, R2-5, R2-6, R2-8, R2-10, R2-11, R2-12 | `core/photoscore/`, `agent-notes/fc-photoscore.md` | queued, starts when FA and FB are verified | those IDs |
| FS | Mac app fixes: R4-1 (same as R5-9), R4-3, R5-1, R5-5, R5-2, R5-6, R4-5, R4-6, R4-2, R5-7, R4-11, R4-4, R5-4, R5-12, R4-12 | `platforms/macos/`, `agent-notes/fs-macos-app.md` | verified by the orchestrator: full Xcode unit run exit 0, 512 Swift Testing tests in 54 suites plus 6 XCTest, 0 failed, 0 skipped. Not run in the real app | those IDs |
| FD | Scripts and docs: R6-1, R6-5, R6-6, R6-7, R6-8, R6-9, R6-11, R6-3, and the `ci.sh` swift FAIL path falsification | `scripts/shared/`, `scripts/macos/`, `scripts/ci/ci.sh`, `scripts/tests/`, `scripts/test.sh`, `scripts/README.md`, `Makefile`, `README.md`, `CLAUDE.md`, `documentation/` except `reviews/`, per-crate `Cargo.toml` dependency lines, `agent-notes/fd-scripts-docs.md` | verified by the orchestrator: 5 script tests exit 0. R6-9 and R6-3 handed back to the orchestrator | those IDs |
| W1 | Windows: PowerShell scripts still unexecuted | `scripts/windows/`, `scripts/ci/ci.ps1` | blocked on the user (see WIN-1) | WIN-1 |

`TODO.md`, `Fixed.md`, `tasks.md`, `.gitignore`, the root `Cargo.toml` and `Cargo.lock` belong to the orchestrator.

Blocked on the user: DSM password change, `photosclient` user, a test album for album verification.
