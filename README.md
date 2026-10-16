# synology-native-photos

A native photo app for a Synology NAS, in the spirit of Apple Photos: browse,
view, edit non-destructively, delete safely to the recycle bin, albums and
search. It talks only to the NAS over the DSM Web API.

- `core/`: shared Rust core (API client, sync, local index), exposed through UniFFI.
- `platforms/macos/`: the macOS app (SwiftUI and AppKit).
- `platforms/windows/`: planned.

See `documentation/architecture.md` for how the pieces fit, and
`documentation/platforms/` for per platform build and test notes.

## Quick start (macOS)

```bash
scripts/macos/setup.sh        # toolchain, idempotent
scripts/test.sh               # core and macOS unit tests
scripts/ci/ci.sh              # the full local CI gate
```

Licensed under the terms in `LICENSE`.
