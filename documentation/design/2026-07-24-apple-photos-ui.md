# Apple Photos-style UI + keyboard model (design spec)

Goal: make the Mac app look and feel as close to Apple Photos as feasible, native macOS, keyboard-driven. This is a REPLICATION brief: mirror Photos' system-native look, do not invent a custom identity (that would read as an off-brand knockoff).

## Visual tokens (system-native, not custom)
- Color: macOS semantic colors only. windowBackgroundColor / controlBackgroundColor for chrome, selectedContentBackgroundColor (system accent) for selection, secondaryLabelColor for counts/captions. Auto light/dark.
- Type: system font (SF Pro). Sidebar items .body; date section headers .title3 semibold; counts .caption secondary.
- Density/shape: Photos-like tight justified grid, square-cropped thumbnails, small inter-item gap, subtle rounded corners on selection only.

## Layout
- NSSplitView: left sidebar + right content.
  - Sidebar: Library, Albums (later), and the Personal / Shared spaces (replaces the current top segmented toggle). Section list styled like Photos' source list.
  - Content: justified square-thumbnail grid with date section headers; a zoom slider in the toolbar (fewer/larger <-> more/smaller); smooth scroll from the local index (windowed).
- Detail viewer: centered photo on a dimmed backdrop, chrome minimal, arrow-key paging between photos, Escape to close.

## Selection
- Single click selects (accent ring). Shift-click range, Cmd-click toggle. Selection count in toolbar. Cmd-A select all. Foundation for delete/album actions.

## Keyboard model (Apple Photos conventions)
- Left/Right: previous/next photo (selection moves, auto-scroll to keep visible).
- Up/Down: move by a full row.
- Space: toggle QuickLook of the selected photo (Finder/Photos behavior). In detail, Space toggles the viewer.
- Return/Enter: open full detail view. Escape: close detail / clear selection.
- Delete or Cmd-Delete: delete selected -> routes to SAFE trash-move + confirm (Phase 2). Until real delete lands, the key is wired to a clear "coming soon / confirm" affordance, never a destructive no-op that lies.
- Cmd-A: select all.

## Signature
The memorable element is not a visual flourish but the keyboard-first fluency: instant arrow navigation and space-to-preview, powered by the local windowed index so it never waits on the NAS. That responsiveness IS the Photos feel.

## Sequencing
Build AFTER: (1) thumbnail unit_id fix (so photos actually render, cannot polish an empty grid), (2) keychain/signing fix. Then implement sidebar + justified grid + selection + keyboard map + detail viewer, iterating on real rendered photos.
