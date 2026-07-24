# TODO — synology-native-photos

Only pending work. Completed items live in `Fixed.md`. Live scratch progress in `.superpowers/sdd/progress.md` (gitignored).

## In progress

- [ ] Apple Photos-style UI + keyboard model: sidebar, justified zoomable grid, multi-select, polished detail viewer, keyboard map (arrows/space/return/escape/cmd-A, delete stubbed to a safe-confirm until Phase 2). Brief: `.superpowers/sdd/fix-apple-photos-ui-brief.md`. Design spec: `documentation/design/2026-07-24-apple-photos-ui.md`.
- [ ] Fix test pollution of real UserDefaults: `LoginView.swift` `LoginPreferencesStore.save()` uses `.standard`, so running the test suite wrote fixture host/username (`devicetoken-send.local` / `devicetokenresend`) into the real app prefs. Inject `UserDefaults` into `LoginFormModel` for load AND save; tests use an isolated suite. (Real prefs already cleared manually.)

## Security (before real use)

- [ ] Change the DSM password `xatkiW-pitkew-dizno7` (exposed in chat during debugging).
- [ ] Switch the app from the main DSM account to a dedicated least-privilege `photosclient` user (Photos-only). Main account used during dev only. Steps in `documentation/phase0-probe-results.md`.

## Empirical NAS probes

- [ ] Delete-semantics probe on a throwaway asset: verify Synology recycle-bin / trash API (soft-delete path vs permanent) before building delete. Note: `SYNO.Foto.Browse.RecycleBin` / `Trash` did NOT appear in the API.Info probe; delete likely goes through `SYNO.Foto.Browse.Item` delete method or `SYNO.Foto.BackgroundTask.File`. Probe to confirm the safe (recoverable) path.

## Phase 2: manage (own plan)

- [ ] Safe-delete (trash-move) + confirm; wire the stubbed Delete keyboard action to it. Gated on the delete-semantics probe.
- [ ] Albums (browse, create, add/remove); replace the sidebar Albums placeholder.
- [ ] Search + favorites.
- [ ] Plan: `documentation/plans/2026-07-25-phase2-manage-implementation.md`.

## Phase 3+

- [ ] Non-destructive editing (upload edited copies as new assets; originals immutable).
- [ ] Grid date-section headers (if deferred by the UI overhaul).
- [ ] QuickConnect / DDNS remote access.
- [ ] Windows UI (core already designed to allow it).
