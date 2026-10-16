import AppKit
import UniformTypeIdentifiers
import PhotosCore

/// Pure filename/type derivation behind dragging a photo or video out to
/// Finder, kept free of `NSFilePromiseProvider` so it is directly testable.
///
/// This never re-derives the original bytes' actual format by inspecting
/// content: it trusts `QuickLookFilename.derive(for:)` (already shipped for
/// the QuickLook preview path, see `Detail/DetailQuickLookView.swift`) for
/// the filename, the exact same source of truth the viewer itself uses, so
/// a dragged-out file and the one QuickLook previewed always agree on name
/// and extension.
enum PhotoDragExport {
    /// The Uniform Type Identifier `NSFilePromiseProvider` needs, derived
    /// from the filename's own extension.
    ///
    /// `UTType(filenameExtension:)` never actually returns `nil` for a
    /// syntactically valid extension: an extension with no registered
    /// system UTI still comes back as a synthesized `dyn.*` placeholder
    /// identifier (verified: it still conforms to `.data`, so it is a
    /// perfectly usable, if opaque, UTI). This is normalized to the plain
    /// `public.data` identifier for an unrecognized/exotic extension (e.g.
    /// some RAW variants) so the pasteboard advertises a stable, standard
    /// type rather than a one-off synthesized identifier; the actual
    /// filename and extension Finder ends up writing are controlled
    /// entirely by `fileNameForType` below, not by this UTI, so this
    /// normalization never affects what file the user actually gets.
    static func fileType(for asset: Asset) -> String {
        let filename = QuickLookFilename.derive(for: asset)
        let ext = (filename as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return UTType.data.identifier
        }
        return type.identifier.hasPrefix("dyn.") ? UTType.data.identifier : type.identifier
    }
}

/// Fulfills one `NSFilePromiseProvider` drag by downloading the asset's
/// ORIGINAL file (never a thumbnail, never an edited/derived copy) via the
/// existing `PhotosCoreClient.downloadOriginal(unitId:)` and copying it to
/// wherever Finder asks the promise to land.
///
/// Read-only and safe by construction: this only ever downloads from the
/// NAS and writes into the drop destination Finder itself chose (typically
/// the Desktop or a folder the user dragged onto). It never uploads,
/// deletes, or otherwise mutates anything on the NAS, satisfying safety
/// invariant #1 (originals are never touched) the same way the QuickLook
/// preview path already does.
final class PhotoExportPromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let asset: Asset
    private let space: Space
    private let client: PhotosCoreClient
    /// Serial by design: `NSFilePromiseProvider` already calls back on its
    /// own dedicated operation queue, and a drag only ever promises one
    /// asset at a time from this delegate instance (a fresh delegate is
    /// created per dragged item, see `PhotoGridController`), so there is
    /// never more than one fulfillment in flight through this queue.
    private let queue = OperationQueue()

    init(asset: Asset, space: Space, client: PhotosCoreClient) {
        self.asset = asset
        self.space = space
        self.client = client
        queue.maxConcurrentOperationCount = 1
        super.init()
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        QuickLookFilename.derive(for: asset)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        let a = asset, s = space, c = client
        Task {
            do {
                // unit_id, not id: the download endpoint keys on unit_id
                // the same way thumbnail/QuickLook preview already do.
                let downloadedPath = try await c.downloadOriginal(
                    space: s, unitId: a.unitId, cacheKey: a.cacheKey)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
                try FileManager.default.copyItem(atPath: downloadedPath, toPath: url.path)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
