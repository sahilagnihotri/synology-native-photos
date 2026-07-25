# Detail viewer rework (Apple Photos parity) — 2026-07-25

> **Status:** DONE

Feedback from the user with screenshots: the current detail viewer shows a black
box instead of the photo, appears as a small centered floating modal, and lacks
Apple Photos conveniences (full right pane, back button, zoom control, Cmd+arrow
navigation).

## Diagnosis (verified by reading the code + a real NAS type tally)

- The library is 126 `photo` + 47 `live` (Live Photo JPG+MOV pairs), and zero
  plain `video` items. `parse_media_kind` (`core/synology-api/src/browse.rs:113`)
  maps `live` to `MediaKind.unknown`, and `DetailViewerHost`
  (`app/SynologyPhotos/Detail/DetailQuickLookView.swift:358`) only routes
  `mediaKind == .video` to the AVPlayer. So every asset in this library takes the
  QuickLook branch: the AVPlayer/video work is NOT the cause of the black box.
- The black box comes from the QuickLook branch:
  1. The loader's `catch` is a silent no-op (`DetailQuickLookView.swift:289`), so
     any `downloadOriginal`/`store` failure leaves the preview empty (black) with
     nothing surfaced.
  2. `QLPreviewView` is set as the `NSScrollView` `documentView` at frame `.zero`
     (`DetailQuickLookView.swift:189, 207`) with no sizing, so it can render
     nothing even when a preview item is assigned.
- Presentation: a `.sheet` with only `.frame(minWidth: 640, minHeight: 480)`
  (`RootView.swift:234-251`) collapses to a small centered modal.

## Goals

1. Detail fills the right pane with the sidebar visible (move out of the sheet
   into the `NavigationSplitView` detail area, driven by `detailIndex`).
2. Never a silent black frame: explicit loading and error states.
3. A back button and a zoom control (slider) in a viewer toolbar.
4. Keyboard: Cmd+Down opens the selected photo into detail; Cmd+Up returns to the
   grid. Keep Return / double-click to open and Escape to close.

## Approach

- **Presentation.** Replace the `.sheet` in `RootView` with a conditional inside
  the split view's detail column: when `detailIndex != nil`, show the viewer
  (filling the pane); otherwise show the grid. Preserve the existing
  `detailIndex` state, paging binding, and grid-selection sync.
- **Rendering.** For photos and live stills, render the downloaded original with
  a correctly sized image view (fills, aspect-fit, centered) instead of a
  zero-framed QLPreviewView. Keep a real `.video` path for when true videos
  appear. Show a `ProgressView` while the download runs and a labeled error state
  (with a retry) if it fails, so a failure is visible, never a blank frame.
- **Zoom.** Keep scroll/pinch magnify, and add a toolbar slider bound to the same
  magnification value (needs a binding/coordinator into the zoom container, which
  today has no SwiftUI binding). Double-click still resets to fit.
- **Toolbar.** A leading back button (chevron.left) that returns to the grid, the
  zoom slider, and the existing info toggle, laid out as a top bar over the image
  (matching Apple's chrome), or the pane's own toolbar.
- **Keyboard.** Add `KeyCode.downArrow` + command in the grid key map
  (`GridKeyAction.swift`) to open detail, and `KeyCode.upArrow` + command in
  `DetailViewerHost.handleKey` to go back. Keep existing Return/Escape/arrows.

## Files (no new files, to avoid touching project.pbxproj concurrently with the
About-panel work)

- `app/SynologyPhotos/RootView.swift` (presentation move, keyboard wiring)
- `app/SynologyPhotos/Detail/DetailQuickLookView.swift` (rendering, loading/error
  states, toolbar, zoom binding, key handling)
- `app/SynologyPhotos/Grid/GridKeyAction.swift` (Cmd+Down open)
- possibly `app/SynologyPhotos/Detail/DetailZoomModel.swift` (expose a bindable
  magnification)

## Verification

- `xcodebuild test ... -only-testing:SynologyPhotosTests` green.
- Build and RUN the app against the real NAS: open a photo (renders, not black),
  page with arrows, zoom via slider and pinch, back button and Cmd+Up return to
  the grid, Cmd+Down opens, sidebar stays visible throughout.
