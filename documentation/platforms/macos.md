# macOS app

SwiftUI app shell with an AppKit `NSCollectionView` grid, over the Rust core
through UniFFI. Lives in `platforms/macos/`.

## Layout

```
platforms/macos/
  project.yml                   xcodegen spec, the source of the Xcode project
  MySynologyPhotos.xcodeproj    generated from project.yml (tracked)
  MySynologyPhotos/             app sources
  MySynologyPhotosTests/        unit tests
  MySynologyPhotosUITests/      UI tests (drive the app through System Events)
  Generated/                    UniFFI Swift bindings and modulemap (tracked)
build/macos/
  PhotosCore.xcframework        static core lib plus headers (gitignored)
  Generated/GitVersion.swift    short git SHA for the About window (gitignored)
  dist/                         dmg installers (gitignored)
```

## Build

- Open `platforms/macos/MySynologyPhotos.xcodeproj` and build. The PhotosCore
  target's first build phase (`scripts/macos/xcodegen/ensure-xcframework.sh`)
  runs on every build and rebuilds the xcframework through `make xcframework`
  when it is missing or older than any Rust source, `Cargo.toml`, `Cargo.lock`
  or `.udl` file.
- After editing `project.yml`, regenerate: `cd platforms/macos && xcodegen generate`,
  and commit both files.
- `make bindings` regenerates the Swift bindings into `platforms/macos/Generated/`.

## Test

```bash
scripts/test.sh macos                 # unit tests only
ADHOC_SIGN=1 scripts/test.sh macos    # ad hoc signing, for a shell without keychain access
scripts/ci/ci.sh macos                # the CI gate: counts read from the xcresult
```

Never run the UI test target unattended: it raises an automation prompt.

## Package

`make dmg` (or `scripts/macos/package/dmg.sh`) builds the Release app and writes
`build/macos/dist/MySynologyPhotos-<version>.dmg`. The Xcode `Installer` scheme
does the same through `scripts/macos/package/dmg-from-app.sh`. Packaging refuses
an app that is not signed with the expected team.
