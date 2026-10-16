# Windows app

Not built yet. `platforms/windows/` is a placeholder.

## Open decision

The UI technology is not chosen: WinUI 3 in C# over a C ABI, or a Rust native
UI. The repo layout does not depend on the choice. See
`windows-handover.md` in this folder for the trade offs and the first milestone
(read only browse).

## What works today

- The shared core is expected to build on Windows. The local gate there is
  `pwsh scripts/ci/ci.ps1 core` (format, clippy, tests).
- On a Mac, `scripts/windows/check-core.sh` cross checks the core for
  `x86_64-pc-windows-msvc` with cargo-xwin, so Windows breakage in the core is
  caught before it reaches the Windows machine.
- `pwsh scripts/windows/setup.ps1` installs the core toolchain on Windows.
