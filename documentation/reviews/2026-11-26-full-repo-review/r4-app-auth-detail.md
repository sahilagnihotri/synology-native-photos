
## r4-app-auth-detail review, 2026-11-26

Scope: platforms/macos/MySynologyPhotos Auth, Session, CoreBridge, Reachability, Thumbnails, Detail, Trash, Settings and matching tests. All findings READ-ONLY (no xcodebuild, no network). A one-off ImageIO probe could not be compiled because the sandbox blocks swiftc (module cache write refused), so the upscaling question in R4-9 is unmeasured.

### R4-1: Sign-out does not clear the Keychain session when AppEnvironment.host was empty at launch, so the app silently signs back in
- severity: high
- confidence: high
- location: platforms/macos/MySynologyPhotos/RootView.swift:1014 (uses env.host), MySynologyPhotosApp.swift:60-62 (host fixed at launch), Auth/AuthStateMachine.swift:87 (save under the typed host)
- defect: `AppEnvironment.host` is read once at launch from `KeychainSID.loadMostRecentAccount()?.host ?? ""`. `SignOutController` clears `KeychainSID` under that host, not the host of the live session. Separately, `attemptLogin` never removes other stored sessions, so older items accumulate and `loadMostRecentAccount` (no ordering) returns an arbitrary one.
- failure scenario: fresh install (or any launch after a sign-out), log in to https://nas:5001 with remember-me on (default). The session is saved under "https://nas:5001|user". Choose Sign Out: `KeychainSID.clear(host: "", username: "user")` matches nothing, the `try?` swallows it, the login screen appears. Relaunch: `loadMostRecentAccount` finds the session and `restore` lands in the library. The user believed they were signed out. Same if the user types a different host string than the stored one. With two items (two hosts or users) the relaunch may restore either.
- evidence: READ-ONLY. SignOutControllerTests passes the same host to save and to the controller (SignOutControllerTests.swift:15-24), so it cannot see this.
- suggested fix: hold the host of the live session in `AuthStateMachine` (set at login and restore) and pass that to the controller, or call `KeychainSID.clearAll()` on sign-out (single-account app). In `attemptLogin` clear other items before `save`.
- suggested test: log in through `AuthStateMachine.attemptLogin` with host H, build the controller the way RootView does (host "" from a fresh `AppEnvironment`), sign out, assert `KeychainSID.loadMostRecentAccount()` is nil.

### R4-2: Detail viewer can show the previous photo's image for the current photo (late load overwrites newer state)
- severity: high
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Detail/DetailQuickLookView.swift:233-246 (`load`), :253-258 (`loadFullResolutionIfNeeded`), :586-592 (`.task(id:)` and the zoom `Task {}`)
- defect: one `DetailImageLoader` is reused across paging. `.task(id: asset.id)` cancels the old task, but `load` never checks cancellation or that the asset is still current, and the awaited chain (UniFFI download, `Task.detached` decode) is not cancellable: the generated bindings contain no cancellation handler (grep of Generated/PhotosCore.swift finds none). The cancelled call returns normally and writes `state = .loaded(oldImage)`. `loadFullResolutionIfNeeded` runs in an unstructured `Task {}` that is never cancelled and assigns `fullResolution` for whatever asset it started with; `displayImage` prefers `fullResolution`, and `load` only resets it at the start of the next load.
- failure scenario: open photo A (uncached, slow download), press Right to B (already cached, loads at once), then A's download finishes: `state = .loaded(A)` after B loaded. `ZoomableImageView` already has `lastAssetId == B`, so the `imageView.image !== image` branch swaps A's pixels in. The pane shows A under B's info panel, and Delete or Edit act on B. Variant: zoom A past fit, page to B while A's full decode runs; `fullResolution` becomes A's image.
- evidence: READ-ONLY. DetailImageLoaderTests never overlap two loads.
- suggested fix: record the asset id at the start of both methods and discard the result unless `Task.isCancelled == false` and the id equals a `currentAssetId` property; cancel the zoom task on id change.
- suggested test: loader whose `loadDisplay` suspends on a continuation for A; start load(A), then load(B) to completion, resume A, assert `state` still holds B's image. Same for the full-resolution path.

### R4-3: Unit tests still touch the real certificate pin store, and one deletes the pin of the user's real NAS host
- severity: medium
- confidence: high
- location: platforms/macos/MySynologyPhotos/Auth/KeychainSID.swift:285-292 (`pinsDir` uses real Application Support, no test isolation); platforms/macos/MySynologyPhotosTests/LoginViewModelTests.swift:126-131, :162-164
- defect: October isolated the Keychain items (`KeychainService.name` adds `.tests`), but the pin store moved to files and `pinsDir()` ignores `isUnitTestHost`. Every pin test writes into `~/Library/Application Support/SynologyNativePhotos/pins`. `loginTargetsTypedHostNeverTheCertSubject` uses the real host `https://fafnir.ladon-pirate.ts.net:5001`, saves a fake pin (bytes 5,5,5,5) and its `defer` runs `KeychainCertPin.clear(host: typedHost)`.
- failure scenario: dev Mac with a real approved pin for that host. Running the app suite makes the first `submit` load the real pin (`.approved`), so the test fails with "expected needsApproval", and the `defer` still deletes the real pin file. Next real launch: `restore` gets `pin == nil`, falls back to system trust, fails against the self-signed/Tailscale certificate and lands on `.expired`, forcing a fresh TOFU approval.
- evidence: READ-ONLY.
- suggested fix: inject the pins directory (tests use a temp dir), and use a reserved host such as https://pin-test.invalid in the test.
- suggested test: a guard that the pins directory under the test host differs from the real one, or a test that snapshots the real pins directory before and after the suite.

### R4-4: A video whose download is still running starts playing after the viewer was closed
- severity: medium
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Detail/DetailVideoPlayerView.swift:326-339 (unstructured `Task`), :350-355 (`dismantleNSView` does not reset `lastAssetId`)
- defect: `updateNSView` starts a `Task` that downloads, then plays if `coordinator.lastAssetId == a.id`. `dismantleNSView` pauses and nils the player but leaves `lastAssetId` set and cannot cancel the task. After the viewer is closed (Esc), the late task passes its guard, assigns a new `AVPlayer` to the dismantled view's `playerView` and calls `player.play()`.
- failure scenario: open a 1 GB video, press Esc while it downloads; when the download completes, audio plays with no UI and no way to stop it until the app quits (the closure retains the player).
- evidence: READ-ONLY.
- suggested fix: keep the `Task` handle in the coordinator, cancel it and set `lastAssetId = nil` in `dismantleNSView`, and check `Task.isCancelled` before `play()`.
- suggested test: coordinator-level test that a dismantled view ignores a late completion.

### R4-5: Recently Deleted restore or permanent delete that fails part way leaves a stale list, and the retry can never succeed
- severity: medium
- confidence: high
- location: platforms/macos/MySynologyPhotos/Trash/RecentlyDeletedModel.swift:119-126 (restore catch), :147-154 (empty catch); core/photoscore/src/lib.rs:1063-1076, :1099-1101
- defect: the core processes paths sequentially and stops at the first failure after earlier ones already moved or were deleted. The model's `catch` only sets `errorMessage`; it does not reload and keeps `selection`. The core also does not reindex after a partial restore (reindex only after the loop), so restored items are missing from the library until the next sync.
- failure scenario: select 3, item 2 fails. Item 1 is restored but the grid still shows all three. Retrying sends item 1 again, whose recycle path is gone, so the core fails at `restored == 0` and items 2 and 3 are never attempted. Same loop for Delete Permanently, where the user is told "Could not permanently delete" although item 1 was deleted. (This is also the untested "restored N of M" message in TODO.md: the message comes from the core and the model shows it only as an alert.)
- evidence: READ-ONLY. FakePhotosCore.restoreRecentlyDeleted and emptyRecentlyDeleted are all-or-nothing and never mutate the fake bin, so no test can model it.
- suggested fix: call `await load()` in both catch blocks (selection is intersected with what remains); in the core, trigger the reindex for the restored subset before returning the partial error.
- suggested test: fake whose restore removes item 1 from its bin then throws; assert the model reloads, drops item 1 from the selection, and the retry argument list excludes it.

### R4-6: Context menu "Delete Permanently" and "Restore" act on the whole existing selection plus the clicked item
- severity: medium
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Trash/RecentlyDeletedView.swift:104, :110
- defect: the comment says the action targets what was clicked, but the code only adds the clicked item when it is unselected and never clears other selected items. The confirm shows only a count.
- failure scenario: select 40 items, scroll so they are off screen, right-click one unselected item, choose Delete Permanently. `pendingEmptyPaths` holds 41 paths and the alert says "41 items". The confirm is shown and matches what is deleted, so this is a trap, not an unconfirmed delete, but the delete is irreversible.
- evidence: READ-ONLY.
- suggested fix: if the right-clicked item is not selected, replace the selection with just that item (Finder behaviour).
- suggested test: model helper `selectForContextMenu(path)`; assert selection == [path] when it was not selected.

### R4-7: Downloaded originals stay in the system temp folder after sign-out and across launches
- severity: medium
- confidence: high
- location: core/photoscore/src/lib.rs:872-877 (writes `syno-orig-<digest>` into `std::env::temp_dir()`); platforms/macos/MySynologyPhotos/Detail/DetailQuickLookView.swift:107-168 (`TempFileCache`); Session/SignOutController.swift:104-112
- defect: every original viewed, edited or played is written whole to `$TMPDIR/syno-orig-*` by the core and nobody deletes it (`OriginalImageCache.ingest` copies it and leaves the source; grep shows `removeItem` only on cache-owned copies). `TempFileCache.clearAll` removes only paths in its in-memory `order`, so files from earlier launches in `$TMPDIR/MySynologyPhotosQuickLook` are never tracked. Sign-out wipes `Caches/.../cache` but neither location.
- failure scenario: user views 200 photos and 20 videos, signs out so someone else can use the Mac; the full-size originals remain readable in `$TMPDIR` until the OS cleaner runs. Disk also grows while signed in, on top of the 4 GB `OriginalImageCache` budget, because each original exists twice.
- evidence: READ-ONLY.
- suggested fix: delete the core's returned path after ingest or copy, empty `MySynologyPhotosQuickLook` on launch and on sign-out, or have the core write under the account cache dir that sign-out already wipes.
- suggested test: after `ingest` of a core path, assert the source no longer exists; sign-out test that pre-creates an untracked file in the quicklook dir and asserts it is gone.

### R4-8: Session expiry during use never routes back to login (`markExpired` has no callers)
- severity: medium
- confidence: high
- location: platforms/macos/MySynologyPhotos/Auth/AuthStateMachine.swift:151
- defect: only `restore` can produce `.expired`. Grep finds no caller of `markExpired`. When DSM invalidates the sid mid-use, core calls fail with `CoreError.Auth`, which views render as text (crawl failure banner, "Sign in failed. ...").
- failure scenario: NAS reboots or the session lapses after hours: every thumbnail, download, delete and recycle-bin call fails with no route back to login except Sign Out, which also wipes the caches (R4-1 aside). A retryable network error during `restore` also lands on `.expired` with the misleading "Your session expired" text and no retry.
- evidence: READ-ONLY (grep).
- suggested fix: map `.Auth` from data paths to `auth.markExpired()` while keeping library state mounted; give the network-error restore its own retry state.
- suggested test: a crawl or delete that returns `.Auth` flips `auth.phase` to `.expired`.

### R4-9: Edited copy loses colour profile and metadata, and the decode path may upscale small originals
- severity: medium
- confidence: medium for metadata and colour (read), low for the upscale (unmeasured)
- location: platforms/macos/MySynologyPhotos/Detail/CropRotateTransform.swift:86 (DeviceRGB context), :125 (no source properties); Detail/PhotoEditorView.swift:238, :255-264 and Thumbnails/ImageDownsample.swift:8-15
- defect: `rotate` draws into `CGColorSpaceCreateDeviceRGB()`, so a Display P3 source is reinterpreted as device RGB with no profile embedded, while a crop-only edit (steps 0) keeps the source space, so behaviour depends on the edit. `jpegData` passes no source properties, so EXIF date taken, GPS and camera are dropped; Synology then indexes the copy by file time, so it appears at today's date. Separately the editor's source comes from `OriginalImageCache.fullImage` (max pixel 8192) via `kCGImageSourceCreateThumbnailFromImageAlways`; originals above 8192 px are silently downscaled, and I recall ImageIO enlarging smaller images to `kCGImageSourceThumbnailMaxPixelSize` with that option, which would turn a 4032x3024 photo into an 8192x6144 blurry upscale. I could not measure this (sandbox blocks swiftc). The editor therefore edits a decoded bitmap, never the true original bytes, by design.
- failure scenario: edit an iPhone P3 HEIC: saved JPEG has shifted colours and no taken-date and lands at the top of the timeline; if the upscale holds, it is also a very large soft file.
- evidence: READ-ONLY. Orchestrator should run a 20-line ImageIO script outside the sandbox: create a 100x50 JPEG, call `ImageDownsample.downsample` with maxPixel 8192, print the size.
- suggested fix: use the source image's colour space for the context, copy EXIF/GPS/TIFF properties into the destination and set DateTimeOriginal, never exceed the source's own pixel size (use `kCGImageSourceCreateThumbnailFromImageIfAbsent` or cap to the real width and height), warn on downscale.
- suggested test: render a P3-tagged CGImage and assert the output JPEG is not DeviceRGB and has DateTimeOriginal; decode a 100x50 file at 8192 and assert width <= 100.

### R4-10: Sign-out leaves the local asset index of the previous account on disk and in the running core
- severity: medium
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Session/SignOutController.swift:104-112, MySynologyPhotosApp.swift:18-19, core/photoscore/src/lib.rs:257-272
- defect: sign-out wipes `cacheDir` (and the core removes `cacheDir/thumbs`) but never `dbDir`, the GRDB index of the whole library (filenames, dates, GPS, captions). `PhotosCore` is not re-created, and core `sign_out`/`login` do not touch the store; grep of the persistence crate finds no account scoping.
- failure scenario: sign out of A, sign in as B on the same Mac: the grid is first built from A's rows until B's crawl or reconcile replaces them, and A's metadata stays readable on disk after "sign out", contradicting the controller's "tear this one account down completely" doc. R3 should confirm how the crawl treats rows B does not own.
- evidence: READ-ONLY.
- suggested fix: record the account (host and username) with the index and clear it on sign-out or on a login that differs from the stored one.
- suggested test: core-level test that a login as a different user empties the index; app test that sign-out removes dbDir contents.

### R4-11: A failed Save in the photo editor shows nothing to the user
- severity: low
- confidence: high
- location: platforms/macos/MySynologyPhotos/Detail/PhotoEditorView.swift:110-111
- defect: the canvas shows a failure message only for `.failed` when `sourceImage == nil`. After a render or upload failure `save` sets `.failed(msg)` while `sourceImage` is set, so the default branch draws the normal editor and the message is never displayed.
- failure scenario: NAS unreachable or upload refused: the saving overlay disappears, the editor looks normal, the user assumes it saved or retries blindly.
- evidence: READ-ONLY (the only use of the failed message is `failureView`, line 111).
- suggested fix: show the failed message in the header or an alert whenever state is `.failed`.
- suggested test: view-model assertion that a save failure exposes a user-visible message binding.

### R4-12: Edited filename has only HHmmss, and a partial save invites a duplicate
- severity: low
- confidence: medium
- location: platforms/macos/MySynologyPhotos/Detail/PhotoEditorModel.swift:154-163; core/photoscore/src/lib.rs:992-1004
- defect: names are `<base>-edited-HHmmss.jpg` with `overwrite=false`. A same-named existing file is skipped by DSM (original safe), and whether the call then reports success must be confirmed on the NAS, so the edit may be dropped silently. If the upload succeeds and `trigger_reindex` throws, the model shows failure with Save still enabled; a retry uploads a second copy under a new timestamp.
- failure scenario: edit IMG_1.heic at 10:10:10 on two different days, or two different IMG_1 files in the same second: the second edit may not be stored. Reindex failure then retry: two edited copies.
- evidence: READ-ONLY (File Station skip-on-existing behaviour is unconfirmed here).
- suggested fix: include date and asset id in the name; treat reindex failure as non-fatal after a successful upload.
- suggested test: two saves with the same base name and time produce distinct filenames.

### R4-13: `OriginalImageCache` can delete or replace a file another task is about to decode
- severity: low
- confidence: low
- location: platforms/macos/MySynologyPhotos/Thumbnails/OriginalImageCache.swift:175-190, :281-297, :331-340
- defect: `ensureFileURL` returns a URL and the decode runs off the actor, so a concurrent `ingest` of the same cacheKey (actor reentrancy at `await download()`) removes and recreates the destination, and `evictIfNeeded` can evict the previous entry while it is being read when the budget is small. Leftover `.ingest-*` files from a crash are never counted or cleared (`clear()` only removes tracked names).
- failure scenario: rapid open/close of the same uncached photo, or a 256 MB budget with large originals: one decode fails with "This file could not be opened as an image."
- evidence: READ-ONLY.
- suggested fix: de-duplicate in-flight downloads per cacheKey, pin a file while decoding, sweep `.ingest-*` at scan.
- suggested test: two concurrent `displayImage` calls for one key with a counting download closure: one download, two successful decodes.

### Checked and clean
- Keychain: session and device token items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and `kSecAttrSynchronizable=false`. Password and OTP are never stored: `LoginPreferences` holds host, username and two toggles. No `print`, `NSLog`, `os_log` or `Logger` in the app target (grep). Password stays in `LoginFormModel` memory only.
- Keychain test isolation for sessions and device tokens: complete (`.tests` service suffix under `isUnitTestHost`); the gap is the pin file store (R4-3). The UI test target only does a link smoke.
- Skip-certificate toggle: `LoginPreferencesStore.load` removes the old key and `save` never writes it, so it cannot persist; `restore` hard-codes `allowUntrustedTls: false`; `attemptLogin` always passes `verifyTls: true`. Pin file name is a percent-encoded host (no traversal).
- Cache file names: `OriginalDiskName` is a hex FNV hash plus a sanitized extension, so a hostile cacheKey or filename cannot escape the directory. `TempFileCache` names sanitize `/` and `..`. The 64-bit hash collision risk is negligible.
- Edit invariant 1: upload is `saveEditedPhoto` with `overwrite=false` into `/home/Photos/Edited`, `.jpg` name from a sanitized base; no code path names the original in a write. Rotation maths: negative CG angle gives clockwise, odd steps swap width and height, the crop is top-left normalised in rotated space and used with `CGImage.cropping` (top-left pixels) in the same space; EXIF orientation applied once (`kCGImageSourceCreateThumbnailWithTransform`), and the pixel orientation is not re-applied by the renderer.
- Delete from the viewer: toolbar, context menu and Delete key all call `requestDeleteCurrent` into the same `onDelete` closure as the grid, no-op when the asset is not loaded.
- Recently Deleted: confirm every time, `confirmEmpty` acts on the paths captured at `requestEmpty`, selection keyed by `recyclePath` and intersected after reload (no index-based selection), restore needs no confirm.
- Lead R4-12 (CrawlProgressModel.refresh flips `isComplete` on a transient error): dropped, `refresh` has no caller in the app (grep), only tests.
- Lead R4-9 (drag export delegates released at drag end): belongs to Grid (R5), not re-verified here.
- AVPlayer observers: status KVO is invalidated on paging and on dismantle; no leak found beyond R4-4.
- `PathMonitor` hops to the main actor before mutating; `HostSelector` is unused by the app.
