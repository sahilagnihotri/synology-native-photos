# tasks.md — dispatch state

Live dispatch only. `TODO.md` says what needs doing; this file says who owns what right now.
Status: queued, in-progress, awaiting-verification, verified, abandoned.

## CURRENT (2026-10-16)

| ID | Goal | Owned paths | Worker | Status | Closes (TODO.md) |
|----|------|-------------|--------|--------|------------------|
| W1 | Fix clippy warnings | `core/synology-api/`, `core/sync-engine/` | clippy (Sonnet) | in-progress | Build infra: 63 clippy warnings |
| W2 | Remove dead trash-album core methods and their FFI exports | `core/photoscore/`, `app/MySynologyPhotos/Generated/` (bindings), any Swift caller it must delete | trash-cleanup (Opus) | in-progress | In progress: real delete cleanup |
| W3 | Swift 6 warnings; route PhotoEditorView through OriginalImageCache | `GridZoomModel.swift`, `ThumbnailCache.swift`, `PhotoEditorView.swift`, `OriginalImageCache.swift`, their tests | swift-fixes (Sonnet) | in-progress | Build infra: Swift 6 warnings; Performance: editor cache |
| W4 | Tests for the delete and permanent delete confirm dialogs | delete confirm views/models and their tests | delete-tests (Sonnet) | in-progress | Phase 2: delete confirm UI tests |
| W5 | xcframework self-heal watches Cargo.toml and UDL; defensive .gitignore | `Makefile`, `scripts/`, `.gitignore` | build-infra (Sonnet) | in-progress | Build infra: self-heal; Security: .gitignore |

Blocked on the user: DSM password change, `photosclient` user, one OTP for the recycle bin probe.
