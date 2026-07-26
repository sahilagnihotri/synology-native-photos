import CoreGraphics
import Foundation
import PhotosCore
import SwiftUI

/// Drives the non-destructive photo editor: holds the current rotation and
/// crop, renders the edit to JPEG on Save, and uploads it as a BRAND-NEW photo
/// via `PhotosCoreClient.saveEditedPhoto`.
///
/// SAFETY (the whole point): Save NEVER modifies or deletes the original. It
/// renders a fresh JPEG and hands it to `saveEditedPhoto`, which uploads it as
/// a new file in a dedicated Edited folder and reindexes; the original NAS
/// asset is never named in any write. Cancel/dismiss does nothing remote at
/// all. Kept out of the SwiftUI view so both contracts ("Save uploads the
/// rendered bytes under a new filename", "Cancel makes zero core calls") are
/// directly unit-testable against `FakePhotosCore`.
@MainActor
@Observable
final class PhotoEditorModel {
    /// The editor's lifecycle. `.failed` carries a user-facing line.
    enum State: Equatable {
        /// Downloading/decoding the original for editing.
        case loading
        /// Original loaded; the user is editing.
        case ready
        /// Rendering + uploading the new photo.
        case saving
        /// Upload succeeded; the view dismisses and refreshes.
        case saved
        /// A load, render, or upload failure, with a message to show.
        case failed(String)
    }

    private(set) var state: State = .loading

    /// Running count of 90-degree CLOCKWISE rotations. Kept as a plain Int (not
    /// pre-normalized) so repeated left presses feel natural; callers normalize
    /// via `CropRotateMath` when they need 0...3.
    private(set) var rotationSteps: Int = 0

    /// The crop rectangle in NORMALIZED, rotated-image space (each axis 0...1,
    /// top-left origin). The full unit square means "no crop".
    var normalizedCrop: CGRect = CropRotateMath.fullCrop

    /// The decoded original, set once the view's download+decode resolves.
    /// Editing controls are only meaningful once this is present.
    private(set) var sourceImage: CGImage?

    let asset: Asset
    let space: Space
    private let client: PhotosCoreClient
    private let render: (CGImage, Int, CGRect) -> Data?
    private let now: () -> Date

    /// `render` and `now` are injectable so a test can pin the rendered bytes
    /// and the timestamp without touching real pixels or the wall clock.
    init(
        asset: Asset,
        space: Space,
        client: PhotosCoreClient,
        render: @escaping (CGImage, Int, CGRect) -> Data? = { image, steps, crop in
            PhotoTransformRenderer.renderJPEG(from: image, steps: steps, normalizedCrop: crop)
        },
        now: @escaping () -> Date = { Date() }
    ) {
        self.asset = asset
        self.space = space
        self.client = client
        self.render = render
        self.now = now
    }

    /// Whether the current edit would actually change the photo. An unchanged
    /// "edit" (no rotation, full crop) should not upload a needless duplicate,
    /// so the UI disables Save when this is false.
    var hasEdits: Bool {
        CropRotateMath.normalizedSteps(rotationSteps) != 0 || normalizedCrop != CropRotateMath.fullCrop
    }

    /// The pixel size of the image as currently rotated (before crop), for the
    /// crop overlay's aspect ratio. Nil until the original has loaded.
    var rotatedImageSize: CGSize? {
        guard let sourceImage else { return nil }
        let size = CGSize(width: sourceImage.width, height: sourceImage.height)
        return CropRotateMath.rotatedPixelSize(size, steps: rotationSteps)
    }

    /// Records the decoded original (or a load failure when `image` is nil) and
    /// moves out of `.loading`. Injected by the view once its async
    /// download+decode resolves.
    func setSourceImage(_ image: CGImage?) {
        if let image {
            sourceImage = image
            state = .ready
        } else {
            state = .failed("This photo could not be opened for editing.")
        }
    }

    /// Rotate 90 degrees counter-clockwise. Resets the crop to full so the
    /// crop rect never refers to a stale orientation (matching Photos, whose
    /// crop is always relative to the current orientation).
    func rotateLeft() {
        rotationSteps -= 1
        normalizedCrop = CropRotateMath.fullCrop
    }

    /// Rotate 90 degrees clockwise. Resets the crop to full (see `rotateLeft`).
    func rotateRight() {
        rotationSteps += 1
        normalizedCrop = CropRotateMath.fullCrop
    }

    /// Discard all edits back to the loaded original. Local only.
    func resetEdits() {
        rotationSteps = 0
        normalizedCrop = CropRotateMath.fullCrop
    }

    /// The user dismissed the editor. Purely local: it never uploads, never
    /// touches the core, and never touches the original. Present so the
    /// "Cancel does nothing remote" contract is explicit and unit-testable.
    func cancel() {
        resetEdits()
    }

    /// Renders the edit to JPEG and uploads it as a NEW photo via
    /// `saveEditedPhoto`, then runs `onSaved` (the caller's library refresh)
    /// ONLY on success. The original is never touched. A no-op that makes no
    /// core call when there is no loaded image.
    func save(onSaved: @escaping () async -> Void) async {
        guard let source = sourceImage else { return }
        state = .saving
        guard let jpeg = render(source, rotationSteps, normalizedCrop) else {
            state = .failed("Could not render the edited photo.")
            return
        }
        let filename = Self.editedFilename(originalFilename: asset.filename, date: now())
        do {
            try await client.saveEditedPhoto(filename: filename, jpeg: jpeg)
            state = .saved
            await onSaved()
        } catch {
            state = .failed((error as? CoreError)?.userMessage ?? "Could not save the edited photo.")
        }
    }

    /// Pure filename builder (static so it is directly unit-testable): derives
    /// `<originalBasename>-edited-<HHmmss>.jpg` from the original filename and a
    /// timestamp. The base is sanitized to a single safe path component so a
    /// hostile NAS-supplied filename can never smuggle a path separator into
    /// the upload destination. The output always ends in `.jpg` because the
    /// edit is always re-encoded as JPEG.
    static func editedFilename(originalFilename: String, date: Date) -> String {
        let raw = (originalFilename as NSString).lastPathComponent
        let base = (raw as NSString).deletingPathExtension
        let safeBase = sanitize(base)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        let stamp = formatter.string(from: date)
        return "\(safeBase)-edited-\(stamp).jpg"
    }

    private static func sanitize(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "photo" : cleaned
    }
}
