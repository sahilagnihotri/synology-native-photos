# tasks.md — dispatch state

Live dispatch only. `TODO.md` says what needs doing; this file says who owns what right now.
Status: queued, in-progress, awaiting-verification, verified, abandoned.

## CURRENT (2026-10-16)

The 2026-10-16 parallel batch (W1 to W8) is verified and recorded in `Fixed.md`.

| ID | Goal | Owned paths | Worker | Status | Closes (TODO.md) |
|----|------|-------------|--------|--------|------------------|
| W9 | Recycle bin enabled check before delete | `core/synology-api/src/recycle.rs` and a new module, `core/photoscore/`, `bindings/`, `app/MySynologyPhotos/Grid/DeleteController.swift`, delete dialog views, FakePhotosCore, delete tests | recycle-check (Opus) | in-progress | Phase 2: HIGH recycle bin check |

Blocked on the user: DSM password change, `photosclient` user, go ahead for one real soft delete and restore to verify polling.
