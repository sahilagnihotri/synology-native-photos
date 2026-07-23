# CLAUDE.md — synology-native-photos

Project-specific instructions for Claude Code. These extend the global rules in `~/.claude/CLAUDE.md` (which still apply: no Claude/AI mentions in commits, no dashes in prose, commit straight to `main`, no feature branches, periodic commits).

## What we're building

A native macOS app (Apple Photos-like: browse, view, edit, delete, albums, search) that acts as a client to a Synology 925+ NAS over its Web API. Goal: help the user migrate off iCloud while keeping an independent double backup.

- **Mac-first, reusable core.** Build the best native Mac app now. Design the core logic (Synology API client, sync engine, models, local index) so a Windows UI is a future project, not a rewrite. User lives on Mac; Windows is deferred.
- **Full Apple-Photos parity is the target**, delivered in safe phases (read-only browse first, then delete/albums/search, then editing).
- **Synology-only scope.** The app touches ONLY the NAS. It never touches the iPhone camera roll, Mac Photos library, or iCloud. iCloud integration is a possible future separate project, not part of this one.

## Non-negotiable safety invariants

1. **Never destroy an original.** Edits are non-destructive: duplicate-before-edit or sidecar, upload edited copies as new assets. The original file on the NAS is immutable.
2. **Delete is soft + confirmed.** Deletes route through Synology's recycle bin / a recoverable trash, and always require confirmation. Match Apple's "Recently Deleted" safety net.
3. **Never propagate to iCloud/phone.** Nothing this app does may reach the iPhone or iCloud. They are separate, independent backups by design.

## Working rules for Claude

- **Plans live in `documentation/plans/`** using `YYYY-MM-DD-<descriptive-name>.md`. Always save the plan there (in addition to any internal plan file). When a plan is fully implemented, move it to `documentation/plans/done/` and mark `> **Status:** DONE`.
- **Delegate to sub-agents and sub-tasks aggressively to keep the main context clean.** Do NOT read large raw outputs (research transcripts, big JSON, long logs) into the main thread. Dispatch a sub-agent to digest raw material and return only the distilled conclusions. Parallelize independent work via the Task/Agent tools.
- **Periodic commits.** After each logical chunk of work, commit with small, human-sounding messages grouped by logical change. Never mention Claude/AI. Push when appropriate.
- **Adversarial review when it matters.** Before finalizing architecture decisions or shipping risky changes (anything touching delete, edit, or sync), run an adversarial review (skeptic sub-agents or `/ultrareview`) rather than trusting the first design.
- **Quality bar: catch bugs before deployment.** For a client app this means unit tests on the core, integration tests against a real/mocked DSM, UI tests for the grid and destructive actions, and a security pass on auth/secrets handling. Suggest additional test types proactively.

## Technical direction (from research, to be confirmed in the plan)

- **UI:** SwiftUI app shell with an AppKit `NSCollectionView` (via `NSViewRepresentable`) for the photo grid, because `LazyVGrid` stutters at the 20k-100k library size. QuickLook for detail/preview.
- **Local index:** GRDB (SQLite) mirroring NAS state; scroll from the local DB so remote latency never blocks the UI. Two-tier thumbnail cache (memory + on-disk, keyed by Synology `cache_key`).
- **Shared core:** decision pending between Rust+UniFFI (max Windows flexibility) and a pure-Swift SwiftPM core (one language). Keep the core boundary clean from day one regardless.
- **API:** Synology `SYNO.Foto.*` (personal) / `SYNO.FotoTeam.*` (shared) Web API, auth via `SYNO.API.Auth`. Unofficial/undocumented; version-guard against DSM releases and verify against the user's own NAS.
- **Connectivity:** LAN + Tailscale first (direct IP works for both). QuickConnect/DDNS is on the TODO for later.
- **Secrets:** DSM session/token in the macOS Keychain, never in UserDefaults.

## Deferred / TODO (not in current scope)

- QuickConnect / DDNS remote-access support.
- Windows UI (core is designed to allow it).
- Any iCloud / Mac Photos library integration.
