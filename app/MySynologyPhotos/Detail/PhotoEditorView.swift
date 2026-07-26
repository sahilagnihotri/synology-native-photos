import SwiftUI
import AppKit
import CoreGraphics
import PhotosCore

/// Non-destructive photo editor: crop and 90-degree rotate, saved as a BRAND-NEW
/// photo. Presented as a sheet over the library from the detail viewer's Edit
/// button.
///
/// SAFETY, made explicit in the UI: the original is downloaded READ-ONLY, all
/// editing happens locally, and Save uploads the result as a NEW file
/// (`PhotoEditorModel.save` -> `PhotosCoreClient.saveEditedPhoto`). The original
/// NAS asset is never modified, moved, or deleted. The footer copy says so, and
/// the button reads "Save as New Photo" so there is no chance of a user thinking
/// this overwrites the original.
struct PhotoEditorView: View {
    let space: Space
    let client: PhotosCoreClient
    let cache: TempFileCache
    /// Dismisses the editor sheet.
    let onClose: () -> Void
    /// Refreshes the library after a successful save so the new photo shows up
    /// (may lag until the NAS finishes re-indexing; that is expected).
    let onSaved: () async -> Void

    @State private var model: PhotoEditorModel
    /// The source rotated by the current step count, shown as the live preview.
    /// Recomputed off-main whenever the rotation changes.
    @State private var previewImage: NSImage?

    init(
        asset: Asset,
        space: Space,
        client: PhotosCoreClient,
        cache: TempFileCache,
        onClose: @escaping () -> Void,
        onSaved: @escaping () async -> Void
    ) {
        self.space = space
        self.client = client
        self.cache = cache
        self.onClose = onClose
        self.onSaved = onSaved
        _model = State(initialValue: PhotoEditorModel(asset: asset, space: space, client: client))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            controls
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        // Load the original READ-ONLY, decode it, and hand it to the model.
        .task {
            await loadOriginal()
        }
        // Re-render the preview whenever the rotation changes.
        .onChange(of: model.rotationSteps) { _, _ in
            Task { await updatePreview() }
        }
        // Dismiss once a save has fully completed (the model has already run
        // `onSaved`).
        .onChange(of: model.state) { _, newValue in
            if newValue == .saved { onClose() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Photo")
                    .font(.headline)
                Text("Saves a new photo. Your original stays unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Canvas (image + crop overlay)

    @ViewBuilder
    private var canvas: some View {
        ZStack {
            Color.black
            switch model.state {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityIdentifier("editor.loading")
            case .failed(let message) where model.sourceImage == nil:
                // A load failure (no image to edit): show the reason.
                failureView(message)
            default:
                if let previewImage, let imageSize = model.rotatedImageSize {
                    GeometryReader { geo in
                        let displayRect = Self.fittedRect(imageSize: imageSize, in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(nsImage: previewImage)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: displayRect.width, height: displayRect.height)
                                .position(x: displayRect.midX, y: displayRect.midY)
                                .accessibilityIdentifier("editor.image")
                            CropOverlay(displayRect: displayRect, crop: $model.normalizedCrop)
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            if model.state == .saving {
                savingOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 10) {
                ProgressView().controlSize(.large).tint(.white)
                Text("Saving new photo…")
                    .foregroundStyle(.white)
                    .font(.callout)
            }
        }
        .accessibilityIdentifier("editor.saving")
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .accessibilityIdentifier("editor.failed")
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                model.rotateLeft()
            } label: {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .accessibilityIdentifier("editor.rotateLeft")
            .disabled(model.sourceImage == nil)

            Button {
                model.rotateRight()
            } label: {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .accessibilityIdentifier("editor.rotateRight")
            .disabled(model.sourceImage == nil)

            Button {
                model.resetEdits()
            } label: {
                Label("Reset", systemImage: "arrow.uturn.backward")
            }
            .accessibilityIdentifier("editor.reset")
            .disabled(!model.hasEdits)

            Spacer()

            Button("Cancel", role: .cancel) {
                model.cancel()
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .accessibilityIdentifier("editor.cancel")

            Button("Save as New Photo") {
                Task { await model.save(onSaved: onSaved) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.sourceImage == nil || model.state == .saving || !model.hasEdits)
            .accessibilityIdentifier("editor.save")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Loading + preview

    /// Downloads the original READ-ONLY, decodes it orientation-correct at a
    /// generous working resolution, and hands the pixels to the model. Nothing
    /// here writes to the NAS.
    private func loadOriginal() async {
        do {
            let asset = model.asset
            let path = try await client.downloadOriginal(space: space, unitId: asset.unitId, cacheKey: asset.cacheKey)
            let filename = QuickLookFilename.derive(for: asset)
            let url = await cache.store(path: path, preferredFilename: filename)
            // Decode off-main. A large maxPixel keeps full resolution for
            // typical photos while capping absurdly large images; the thumbnail
            // transform applies EXIF orientation so the pixels match what the
            // viewer showed.
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDownsample.downsample(fileURL: url, maxPixel: 8192)
            }.value
            model.setSourceImage(decoded)
            await updatePreview()
        } catch {
            model.setSourceImage(nil)
        }
    }

    /// Recomputes `previewImage` from the source rotated by the current steps,
    /// off the main thread.
    private func updatePreview() async {
        guard let source = model.sourceImage else { return }
        let steps = model.rotationSteps
        let rotated = await Task.detached(priority: .userInitiated) {
            PhotoTransformRenderer.rotate(source, steps: steps)
        }.value
        if let rotated {
            previewImage = NSImage(cgImage: rotated, size: NSSize(width: rotated.width, height: rotated.height))
        }
    }

    /// Aspect-fit `imageSize` centered inside `container`, returning the
    /// displayed image rect in the container's coordinate space.
    static func fittedRect(imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }
}

/// An adjustable crop rectangle drawn over the fitted image: a bright border
/// with four corner handles (drag to resize) and a draggable interior (drag to
/// move), plus a dimmed surround outside the selection. The selection is kept
/// as a NORMALIZED rect (0...1, top-left origin) in the bound `crop`, which is
/// exactly what `CropRotateMath.pixelCropRect` consumes at render time, so what
/// the user frames is what gets saved.
private struct CropOverlay: View {
    /// The displayed image rect (container coordinates) the crop sits within.
    let displayRect: CGRect
    @Binding var crop: CGRect

    /// Crop start captured at the beginning of an interior move drag.
    @State private var moveStart: CGRect?

    /// Minimum crop extent as a fraction of each axis, so the selection can
    /// never collapse to nothing.
    private let minFraction: CGFloat = 0.06
    private let handleSize: CGFloat = 22

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    /// The crop rectangle in container coordinates.
    private var pixelRect: CGRect {
        CGRect(
            x: displayRect.minX + crop.minX * displayRect.width,
            y: displayRect.minY + crop.minY * displayRect.height,
            width: crop.width * displayRect.width,
            height: crop.height * displayRect.height)
    }

    var body: some View {
        let pr = pixelRect
        ZStack(alignment: .topLeading) {
            dimming(around: pr)

            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: pr.width, height: pr.height)
                .position(x: pr.midX, y: pr.midY)

            // Transparent hit area for moving the whole selection.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: pr.width, height: pr.height)
                .position(x: pr.midX, y: pr.midY)
                .gesture(moveGesture)
                .accessibilityIdentifier("editor.crop")

            handle(.topLeft, at: CGPoint(x: pr.minX, y: pr.minY))
            handle(.topRight, at: CGPoint(x: pr.maxX, y: pr.minY))
            handle(.bottomLeft, at: CGPoint(x: pr.minX, y: pr.maxY))
            handle(.bottomRight, at: CGPoint(x: pr.maxX, y: pr.maxY))
        }
        .frame(width: displayRect.width, height: displayRect.height)
        // The ZStack is sized to the display rect, but its children are placed
        // in container coordinates; offset the whole thing back so those
        // positions land correctly relative to the parent.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Four dim bands filling the area inside `displayRect` but outside `pr`.
    private func dimming(around pr: CGRect) -> some View {
        let d = displayRect
        return ZStack(alignment: .topLeading) {
            dimBand(CGRect(x: d.minX, y: d.minY, width: d.width, height: max(pr.minY - d.minY, 0)))
            dimBand(CGRect(x: d.minX, y: pr.maxY, width: d.width, height: max(d.maxY - pr.maxY, 0)))
            dimBand(CGRect(x: d.minX, y: pr.minY, width: max(pr.minX - d.minX, 0), height: pr.height))
            dimBand(CGRect(x: pr.maxX, y: pr.minY, width: max(d.maxX - pr.maxX, 0), height: pr.height))
        }
    }

    private func dimBand(_ rect: CGRect) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.45))
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
    }

    private func handle(_ corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 1))
            // A larger invisible hit target than the visible dot.
            .frame(width: handleSize, height: handleSize)
            .contentShape(Rectangle())
            .position(x: point.x, y: point.y)
            .gesture(cornerGesture(corner))
    }

    private var moveGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if moveStart == nil { moveStart = crop }
                guard let start = moveStart, displayRect.width > 0, displayRect.height > 0 else { return }
                let dx = value.translation.width / displayRect.width
                let dy = value.translation.height / displayRect.height
                let nx = min(max(start.minX + dx, 0), 1 - start.width)
                let ny = min(max(start.minY + dy, 0), 1 - start.height)
                crop = CGRect(x: nx, y: ny, width: start.width, height: start.height)
            }
            .onEnded { _ in moveStart = nil }
    }

    private func cornerGesture(_ corner: Corner) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard displayRect.width > 0, displayRect.height > 0 else { return }
                let nx = min(max((value.location.x - displayRect.minX) / displayRect.width, 0), 1)
                let ny = min(max((value.location.y - displayRect.minY) / displayRect.height, 0), 1)
                crop = Self.adjust(crop, corner: corner, toX: nx, toY: ny, minFraction: minFraction)
            }
    }

    /// Pure corner adjustment: move `corner` to (`x`,`y`) in normalized space
    /// while keeping the opposite corner fixed, clamped to the unit square and
    /// never smaller than `minFraction` on either axis.
    private static func adjust(_ rect: CGRect, corner: Corner, toX x: CGFloat, toY y: CGFloat, minFraction: CGFloat) -> CGRect {
        var minX = rect.minX
        var minY = rect.minY
        var maxX = rect.maxX
        var maxY = rect.maxY
        switch corner {
        case .topLeft:
            minX = min(x, maxX - minFraction)
            minY = min(y, maxY - minFraction)
        case .topRight:
            maxX = max(x, minX + minFraction)
            minY = min(y, maxY - minFraction)
        case .bottomLeft:
            minX = min(x, maxX - minFraction)
            maxY = max(y, minY + minFraction)
        case .bottomRight:
            maxX = max(x, minX + minFraction)
            maxY = max(y, minY + minFraction)
        }
        minX = max(minX, 0)
        minY = max(minY, 0)
        maxX = min(maxX, 1)
        maxY = min(maxY, 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
