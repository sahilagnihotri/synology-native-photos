# Handover prompt — synology-native-photos

Paste everything below the line into a fresh Claude Code session in this repo
(`/Users/sahil/code/github/synology-native-photos`). It carries all state
needed to continue. Nothing critical lives only in the prior chat: work is
pushed to `origin/main`, and TODO.md / Fixed.md / documentation/ hold the rest.

---

You are continuing work on **synology-native-photos**, a native macOS Apple-Photos-style client for a Synology NAS over its Web API, Rust core (`core/`, exposed to Swift via UniFFI) + SwiftUI/AppKit app (`app/`). Read `CLAUDE.md` (project rules) first; it is authoritative. Also read `TODO.md`, `Fixed.md`, `documentation/design/2026-07-25-detail-viewer-spec.md`, and the plans in `documentation/plans/`.

## Where things stand (all pushed to origin/main, ~290 unit tests + ~237 cargo tests green)
The full READ-ONLY Apple-Photos-parity surface is DONE and shipped:
- Login (2FA + device token), TLS leaf-cert pinning over Tailscale, crawl -> local SQLite index, thumbnail grid (fast NSCollectionView), QuickLook/detail viewer.
- Keyboard model: arrows navigate the grid (do NOT open), double-click/Return open detail, Space QuickLook, Shift+arrow extends selection, Cmd-A, Delete -> honest "coming soon" affordance (NOT wired to real delete yet).
- Detail viewer: zoom+pan on the image, info panel (date/filename/dimensions/size; EXIF/location deferred, Asset model has no such fields), arrow paging, drag-a-photo/video-out-to-Finder export (copies the original, read-only).
- Discovery sidebar: People, Places, Tags, Favorites (all browse + drill into photos). Subjects/Concept tiles list but have no working photo-filter param on this NAS (deferred, not faked).
- Albums: real Browse.Album browser (+ smart/condition). Account currently has ZERO albums, so it shows empty.
- Search: Synology's real server search (SYNO.Foto.Search.Search, method `list_item`, param `keyword`) + DATE-RANGE filter (start_time/end_time unix secs). All other facets (camera/aperture/geocoding/media_type) are SILENTLY IGNORED by the API (proven with bogus-value controls) so they are shown for browsing only, never selectable, NOT faked.
- Video playback: download-then-play-local via AVPlayerView (SYNO.Foto.Streaming is advertised but every method returns err103, unusable). NAS has no true video items yet (only a Live-Photo JPEG), so it is built+correct but untested against real video.
- Signing: Apple Developer team "Agnihotri AS" (5W67TF3579), CODE_SIGN_STYLE Automatic, project-wide in app/project.yml. Bundle id + all keychain/defaults namespaces are `se.agnihotri.synologyphotos.*`. Cert-pin lives in Application Support (not Keychain) -> no repeat keychain prompt. UI tests removed from the default test action (they triggered a System Events automation prompt); run unit tests ONLY: `xcodebuild test ... -only-testing:SynologyPhotosTests`.

## The three authorized next tasks (in priority order, all cross the safety line so read the invariants in CLAUDE.md)

### 1. Recoverable DELETE (user AUTHORIZED the destructive verify)
Design (agreed): Synology Photos delete auto-routes to the DSM per-user recycle bin. `SYNO.Core.RecycleBin` + `SYNO.Core.RecycleBin.User` exist (the Foto API has NO recycle namespace: SYNO.Foto.*RecycleBin = err102). So: real delete = `SYNO.Foto.Browse.Item` method `delete`, id list (err120 if id missing = the method is real). Then list `SYNO.Core.RecycleBin` for a "Recently Deleted" view; restore + permanent-delete (empty from bin) via Core.RecycleBin. Cmd-Z = restore the just-deleted item.
FIRST STEP: a ONE-photo destructive verify the user authorized. Victim already chosen + BACKED UP: `id=73412 unit_id=55758 filename=IMG_8550.JPG`, backup at `$CLAUDE_JOB_DIR/tmp/victim_73412_IMG_8550.JPG` (2588804 bytes) BUT NOTE: that job-tmp dir is per-job and is GONE in a fresh session, so re-back-up the victim (download its original) BEFORE deleting. The harness auto-mode classifier BLOCKS destructive network calls; the user must run the delete themselves via a `! cargo run ...` line, or approve it. Steps: back up victim -> delete via Browse.Item delete -> confirm it appears in SYNO.Core.RecycleBin -> RESTORE it via Core.RecycleBin -> confirm it is back in the library. Prove the delete->recyclebin->restore loop end to end, THEN build the delete UI (route the stubbed Delete key + a Recently Deleted sidebar section + restore + gated permanent-delete with confirm). NEVER permanently delete without explicit confirm + retention.

### 2. Phase 3 EDITING / ROTATE (non-destructive)
Safety invariant #1: never modify an original. Rotate/edit MUST upload the result as a NEW asset (SYNO.Foto.Upload.Item is in the catalog) or a sidecar; the original NAS file is immutable. The Rotate/Edit buttons currently show coming-soon affordances. Design this carefully (bigger task): probe Upload.Item read-first, build an edit pipeline that reads original -> edits locally -> uploads as new -> original untouched.

### 3. MUTATIONS (each modifies NAS state, gate + confirm as appropriate)
Create album, add/remove photos to/from album, name/rename a person (Browse.Person likely has a set-name method), toggle favorite (SYNO.Foto.Favorite). These are additive/reversible mutations but still writes; probe each method read-first, confirm params with bogus controls, and wire with clear UI. Album creation would also make the (currently empty) Albums view useful.

## How to work here (from CLAUDE.md + this session's proven workflow)
- Use SUBAGENTS aggressively for each task (fresh implementer per feature), keep main context clean. Parallelize only across DISJOINT file sets (agents editing the same files collide; the app's RootView/Grid/Detail are hot files). Give an agent an isolated git worktree if it must build while another agent edits shared files.
- Each feature: write a brief to `.superpowers/sdd/<name>-brief.md`, dispatch a general-purpose subagent, then VERIFY yourself (build + unit tests) and REVIEW risky ones (esp. delete/edit) before pushing. Commit in small logical commits; human/imperative messages; NO AI/Claude mention anywhere; NO dashes as dashes in prose/comments (grep before commit). Commit straight to `main`, no feature branches. Push after verifying.
- Real-NAS debugging (see CLAUDE.md "Debugging against the real NAS"): host `fafnir.ladon-pirate.ts.net:5001`, Personal space only (Shared = err801). Capture the device token ONCE with a fresh OTP, save session to `$CLAUDE_JOB_DIR/tmp/syno_session.txt`, reuse it (no more OTPs that session). API gotchas: state-reading calls need the `X-SYNO-TOKEN` header (else err119); thumbnails/downloads key on `unit_id` (from additional.thumbnail.unit_id), NOT the item id; prefer reproducing bugs through the real PhotosCore path in a throwaway `core/photoscore/examples/*.rs`, delete after, never commit it. Confirm every unverified API param with a bogus-value control (bogus returning err/empty vs real returning data proves the param); DEFER + log anything unconfirmable, never fake it.
- Creds the user pasted this session (rotate reminder standing): user `sahilagnihotri`. The DSM password was exposed in chat and MUST be changed by the user (it is in TODO.md). Prefer asking for a fresh OTP over reusing a chat-exposed password where possible.
- Keep TODO.md + Fixed.md in sync every task (CLAUDE.md rule): move done items to Fixed.md with commit hash, delete from TODO.md.

## Immediate first action in the fresh session
Start with task 1 (delete). Because the destructive call is blocked under auto-mode and the prior job's backup is gone: (a) ask the user for one fresh OTP, log in, save the session; (b) re-back-up victim id=73412 (download original); (c) stage the delete+recyclebin+restore verify as a throwaway example and have the USER run the destructive `cargo run` line via `!` (or explicitly approve it); (d) interpret the recycle-bin/restore result; (e) then build the delete UI + Recently Deleted view. Do NOT permanently delete anything without explicit per-action confirm.
