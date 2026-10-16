# Architecture

One shared Rust core, one native app per platform. The core owns everything
that is not UI; each app is a thin native shell over it.

```
            +-----------------------------------------------+
            |                  core/ (Rust)                 |
            |  synology-api  sync-engine  persistence       |
            |  models        photoscore (the facade)        |
            +-----------------------+-----------------------+
                                    |  FFI boundary (UniFFI)
              +---------------------+---------------------+
              |                                           |
   platforms/macos (Swift)                     platforms/windows (pending)
   SwiftUI + AppKit app                        UI technology not chosen yet
```

## The core (`core/`)

A Cargo workspace whose manifest is at the repo root.

- `synology-api`: the DSM Web API client (`SYNO.API.Auth`, `SYNO.Foto.*`, File Station).
  Version guarded, TLS pinning, no secrets in errors.
- `persistence`: the local SQLite index (assets, albums, sync state, app state).
- `sync-engine`: crawl and delta sync from the NAS into the index.
- `models`: shared value types, exported over UniFFI.
- `photoscore`: the facade the apps call (`PhotosCore`). It is the only crate the
  apps see, and it is where the UniFFI exports live.

The core never touches the iPhone, the Mac Photos library or iCloud. The safety
invariants in `CLAUDE.md` (originals are immutable, delete is soft and confirmed)
are enforced in the core first, so every platform inherits them.

## The FFI boundary

UniFFI 0.29 generates the bindings from the built static library
(`uniffi-bindgen generate --library`). `photoscore` and `models` are two UniFFI
components, so one pass emits two sets of bindings.

- macOS: `make bindings` writes Swift into `platforms/macos/Generated/` (tracked),
  and `make xcframework` packages the static lib and headers into
  `build/macos/PhotosCore.xcframework` (gitignored).
- Windows: not built yet. The bindings for the Windows app will be generated into
  that app's own tree, the same way.

Anything a platform needs that is not UI belongs behind this boundary, so a
second platform is a new shell, not a rewrite.

## Platform apps

- [macOS](platforms/macos.md): the shipped app.
- [Windows](platforms/windows.md): planned, UI technology decision pending.

## Repo layout

```
core/                 shared Rust core
platforms/macos/      macOS app (Xcode project generated from project.yml)
  Generated/          UniFFI Swift bindings and modulemap (tracked)
platforms/windows/    placeholder until the UI technology is chosen
build/                all build outputs (gitignored)
scripts/shared/       platform neutral scripts (core tests, helpers)
scripts/macos/        macOS build, packaging and test scripts
scripts/windows/      Windows setup and checks
scripts/test.sh       test dispatcher: core | macos | windows | all
documentation/        this page, platform pages, plans, reviews, research
```
