# Detail viewer + grid interaction spec (Apple Photos parity)

Captured from user, 2026-07-25. Target: match Apple Photos' viewer and grid interactions.

## Grid navigation + selection
- Left/Right/Up/Down move the focused cell (DONE).
- Shift+Left/Right (and Shift+Up/Down) EXTEND the selection in the grid (currently only shift-CLICK range exists; add shift-ARROW selection extension).
- Double-click a photo opens it in the full detail viewer (wire double-click, in addition to Return/single-click-then-open).

## Detail viewer (immersive)
- Opens to a large, centered, right-side/immersive view of the photo (currently a sheet; move toward Photos' integrated full viewer).
- Left/Right page between photos (DONE, index-based).
- Multiple ways back to the grid: Escape (DONE), a visible back/close affordance, and (Photos) pinch-close / swipe-down gesture where feasible.
- Zoom control ON the image: scroll / pinch / +- to zoom into the photo itself (magnify), with pan when zoomed. (NEW)
- Info panel (toggle, e.g. the i button / Cmd-I): date taken, filename, dimensions (WxH), file size, camera/EXIF if available, location (from Geocoding) if available. Most of this is already in the Asset model or a metadata fetch. (NEW)
- Rotate button: PHASE 3, NON-DESTRUCTIVE. Rotating writes a new asset or sidecar; the original NAS file is NEVER modified (safety invariant #1). Show as coming-soon until Phase 3, like Delete.
- Edit button: PHASE 3, NON-DESTRUCTIVE (edit -> upload as a NEW asset via SYNO.Foto.Upload.Item; original immutable). Coming-soon until then.

## Drag out to Finder (export/copy)
- Dragging a photo/video from the grid OR the viewer to Finder copies the ORIGINAL file out (a read-only export: download original bytes, expose as an NSItemProvider / NSFilePromiseProvider file promise named by filename). Safe, read-only, no NAS mutation. (NEW)

## Video
- Play video inline in the viewer via SYNO.Foto.Streaming (queued separately). type=="video" items.

## Sequencing / safety
- SAFE / read-only, build next: shift-arrow selection, double-click open, image zoom+pan, info panel, drag-to-Finder export. These never mutate the NAS.
- PHASE 3 (non-destructive edit, gated on safety invariant #1): rotate, edit, any orientation/adjustment -> always upload-as-new or sidecar, original untouched. Show coming-soon affordances until built.
- Video playback: its own task (Streaming).
