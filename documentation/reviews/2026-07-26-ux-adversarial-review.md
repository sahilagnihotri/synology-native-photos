# Adversarial UI/UX review vs Apple Photos (2026-07-26)

Read-only review of the native macOS SwiftUI/AppKit app against Apple Photos.
No code was changed. Method: read every view/controller/model under
`app/SynologyPhotos`, both design specs, `TODO.md`, `Fixed.md`, and
grep-verified the key negative claims. Items needing the live GUI are flagged
at the end.

## Bottom line

The engineering under the hood is strong (windowed data source, lazy
day-sections, reuse/flicker guards, honest empty/loading/error states, safe
delete + undo). The gap to "feels like Apple Photos" is almost entirely at the
macOS-native chrome layer and the browsing/organizing model, not the plumbing.
Three things drag the app below the Apple bar most: (1) an almost-empty menu
bar, (2) no right-click context menus anywhere, (3) no Years/Months/Days
browsing or aspect-ratio mosaic.

## Quick wins (high value, low effort)

1. **Build a real menu bar.** `SynologyPhotosApp.swift:131` only replaces
   `.appInfo`; there is no File/Edit/Image/View menu. Strongest "not a native
   Mac app" signal. Surface every shortcut the grid/detail key mappers already
   implement (`GridKeyAction`, `DetailKeyAction`) so they are discoverable, not
   just typeable: Edit (Undo Delete / Select All / Delete), View (Zoom In/Out,
   Show/Hide Sidebar, Show/Hide Info, Actual Size / Zoom to Fit), Image
   (Rotate, Get Info, later Favorite).
2. **Right-click context menus.** Zero `contextMenu`/`NSMenu` anywhere. Apple
   Photos is context-menu-driven. Add an `NSMenu` via `menu(for:)` on the
   grid's `KeyHandlingCollectionView` and a `.contextMenu` in the viewer and
   recently-deleted views. Even Delete / Get Info / Share would land as more
   native.
3. **Move the header controls into the native window toolbar.** Title, crawl
   status, Filter, selection count, Delete, Refresh, zoom slider, and Sign Out
   live in a custom `HStack` (`RootView.swift:465-545`); only search uses
   `.toolbar`. Reads as a web-app header bar and will crowd/clip on a narrow
   window (no overflow handling). Put these in a real `.toolbar { }`; move Sign
   Out into an account/menu affordance.
4. **People tiles should be circles, not squares.** `DiscoveryTileGridView.swift:71`
   clips every tile to a `RoundedRectangle`. Make Person covers `Circle()`-clipped;
   keep albums/places rounded rects.
5. **Hide (or clearly gate) the dead "Subjects" section.** `DiscoveryTile.swift:75`
   sets `collection = nil` for every subject (no working photo filter on this
   NAS). A sidebar section whose tiles do nothing is worse than not shipping it.
   Also "Subjects" is not an Apple label (Apple uses search Categories).
6. **Consolidate the two Filter buttons.** Quick Filter (library) and Search
   Filter (search) have overlapping date popovers in different contexts, and
   the Search Filter shows camera/location facets that do nothing
   (`SearchFilterBarView.swift:112`). Fold Favorites and media-type into one
   filter; drop or bury the non-functional facet browser.
7. **Unify selection visuals.** Main grid draws a 3pt accent ring
   (`PhotoCellView.swift:79`); Recently Deleted uses an Apple-style
   checkmark-circle badge (`RecentlyDeletedView.swift:137-144`). Make the main
   grid match the checkmark treatment.
8. **Grid cell accessibility labels.** Cells set only
   `accessibilityIdentifier` (`PhotoCellView.swift:163`), no
   `accessibilityLabel`, so VoiceOver reads nothing useful. Add e.g. "Photo, 25
   November 2016, IMG_1234.jpg". Same for the zoom slider.

## Medium (meaningful value, moderate effort)

9. **No inline Favorite or rating from the UI.** Viewer chrome
   (`DetailQuickLookView.swift:761`) has no heart; info panel stars are
   read-only (`AssetInfoPanelView.swift:897`). High-frequency Apple control.
   Needs the write API, so "medium" only once that lands.
10. **No Share/export button.** No `NSSharingService`/`ShareLink`; only
    drag-to-Finder (`PhotoDragExport`). Add an `NSSharingServicePicker` in the
    viewer chrome and selection toolbar (bytes already downloaded for drag).
11. **Detail viewer has no filmstrip and no trackpad swipe/scrub.** Paging is
    arrow-key only (`DetailQuickLookView.swift:842`). Add a bottom filmstrip
    (reuse `ThumbnailCache`) and a horizontal swipe/scroll gesture. A
    trackpad-only user currently cannot move between photos in the viewer.
12. **No open/close zoom transition.** Grid to detail is a plain opacity
    crossfade (`RootView.swift:264`). Apple's signature is the photo zooming out
    of its grid cell. A matchedGeometry-style zoom is high-impact polish.
13. **Grid pinch-to-zoom and scroll-to-now.** Zoom is slider-only; no
    magnification gesture. Add an `NSMagnificationGestureRecognizer` driving
    `applyZoom`, a "scroll to now / jump to top" affordance, and Home/End keys.
    The floating scrubber is read-only; drag-to-jump is already scaffolded in
    `GridDateSections`.
14. **Section headers are date-only and inert.** `DateSectionHeaderView.swift`
    shows just the day. Add a location line when geocoding lands (Map planned)
    and make the header a select-whole-section affordance with an overflow menu.
15. **Live Photos are dead stills.** `DetailViewerHost.swift:706` routes "live"
    items as `MediaKind.unknown` to the still renderer; no press-and-hold, no
    grid hover-scrub. For a mostly-iPhone library this is felt. Long-term:
    re-pair still+MOV into a `PHLivePhoto`; interim: press-and-hold to play the
    paired MOV.
16. **Info panel is non-adaptive and non-native.** `AssetInfoPanelView.swift:967`
    hardcodes `.black.opacity(0.6)` + `.white` regardless of appearance, and is
    a custom floating card, not Apple's adaptive popover with a mini-map. Make
    it appearance-adaptive (or a `.popover`) and add a map snippet once
    per-asset location is available.
17. **Crop editor lacks aspect presets and straighten.** `PhotoEditorView`
    CropOverlay is free-form only. Add aspect-ratio presets + a straighten dial
    + flip.
18. **Dynamic Type in the AppKit views.** `DateSectionHeaderView.swift:26`
    (13pt) and `DateScrubberView.swift:29` (12pt) use fixed sizes. Use
    `NSFont.preferredFont(forTextStyle:)`.

## Bigger bets (high value, high effort)

19. **Years / Months / Days / All Photos browsing.** The defining Apple Photos
    interaction and the largest single gap. Today one flat day-sectioned square
    grid with a size slider. `GridDateSections` already computes per-day prefix
    sums, so month/year rollups extend naturally; the real work is the
    four-level model plus the smooth pinch transition that reframes on a
    representative photo between levels.
20. **Aspect-ratio mosaic layout.** The spec chose uniform square crops (Apple's
    "All Photos" tab only). Apple's Days/Months use a justified variable-aspect
    mosaic. Needs a custom layout; pairs with #19.
21. **Albums create/organize + drag-to-album.** Albums are read-only. Cannot
    create, drag photos in, reorder, or make folders/smart albums. Most valuable
    manage-phase feature after delete.
22. **Memories / For You.** Absent. Headline Apple feature; lower priority for a
    NAS client.
23. **Duplicates detection.** Absent. Valuable in a migration-off-iCloud
    context.
24. **Import/upload UI.** No general "add photos to the NAS" flow (only the
    editor's save-as-new path). For migrating off iCloud, a proper import
    (drag files/folders, SD card) is arguably a core workflow.
25. **People naming + merge, captions/titles, batch adjustments, slideshow.**
    All absent (read-only). People naming is the most visible tease (the tiles
    already show a disabled "Add Name").

## Already good (do not regress)

- Empty/loading/error state coverage (tailored per source; explicit
  failed+Retry; honest importing-vs-complete barrier).
- Keyboard model in grid + viewer (arrows, shift-range, Space, Return,
  Cmd-Down/Up, Cmd-A, Cmd-Z undo, Cmd-I). The gap is discoverability (menu
  bar), not the bindings.
- Delete safety: soft delete to recycle, Recently Deleted with restore, gated
  permanent delete, Cmd-Z undo.
- Selection semantics (anchor, shift/cmd) match Finder/Photos.
- Video uses `AVPlayerView` with Apple's own transport controls.

## Needs the running app to judge

- Whether rubber-band (marquee) selection works in empty space given every cell
  is a file-promise drag source.
- Scroll smoothness and thumbnail crispness at 20k-100k.
- Grid->detail transition feel; info-panel legibility over bright photos;
  whether the header `HStack` actually clips at small widths.
- Live Photo / paired-MOV behavior against real assets.
