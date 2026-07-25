import Foundation
import PhotosCore

/// Pure display-string formatting behind the detail viewer's info panel,
/// kept free of SwiftUI so every field's exact text is directly testable
/// without a live view.
///
/// Per the brief: this shows only what `Asset` (the model already loaded
/// for the grid/detail viewer) actually carries. There is no per-asset
/// EXIF or geocoding accessor anywhere in `PhotosCoreProtocol` today (the
/// core's `Place` type is a Geocoding *collection*, i.e. a whole cluster of
/// photos DSM grouped by location for the Places discovery tile, not a
/// field hung off one `Asset`), so camera/EXIF and location are
/// deliberately left out here rather than invented or guessed at. See
/// `AssetInfoFields.exifFollowUpNote` for the exact text surfaced in the
/// panel, and the report/TODO for this as a tracked follow-up (a future
/// per-asset metadata fetch, if DSM exposes one cheaply, is what would fill
/// this in).
enum AssetInfoFormatter {
    /// `Asset.takenAt`/`addedAt` are Unix epoch seconds. Falls back to
    /// `addedAt` when `takenAt` is absent (an asset the NAS never extracted
    /// capture metadata for still has an import date), and to a plain
    /// placeholder when neither is known.
    static func dateTaken(takenAt: Int64?, addedAt: Int64?) -> String {
        guard let epoch = takenAt ?? addedAt else { return "Unknown" }
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        return Self.dateFormatter.string(from: date)
    }

    /// Whether the returned date string came from `taken_at` (the camera's
    /// own capture time) or fell back to `added_at` (when the asset was
    /// added to the library), so the panel can label it correctly rather
    /// than always claiming "Date Taken" for a date that is actually just
    /// an import timestamp.
    static func dateTakenIsCaptureDate(takenAt: Int64?) -> Bool {
        takenAt != nil
    }

    /// "1920 x 1080" when both dimensions are known, `nil` (caller shows a
    /// placeholder) when either is missing. Deliberately not "1920x1080"
    /// (no spaces): matches how Finder's own Get Info panel spaces the
    /// multiplication sign, more readable at a glance.
    static func dimensions(width: UInt32?, height: UInt32?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width) x \(height)"
    }

    /// Human-readable file size ("2.4 MB"), or `nil` when the NAS never
    /// reported one for this asset. Uses `ByteCountFormatter`'s binary
    /// style (1024-based, matching macOS's own Finder/Get Info convention
    /// on Apple platforms) rather than a hand-rolled KB/MB table.
    static func fileSize(_ bytes: UInt64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        return Self.byteFormatter.string(fromByteCount: Int64(bytes))
    }

    /// The exact text shown where a camera/EXIF field would go, honest
    /// about it not being available yet rather than silent about its
    /// absence or inventing a value. Kept as one named constant so the
    /// panel and any test asserting on it read the same wording.
    static let exifFollowUpNote = "Camera details not available yet"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter
    }()
}

/// The complete set of display-ready fields for one asset's info panel,
/// bundled so the SwiftUI view has a single value to read rather than
/// re-deriving each field itself. Building this is a pure function of
/// `Asset`, so it is exercised directly by tests without any view.
struct AssetInfoFields {
    let filename: String
    let dateLabel: String
    let dateValue: String
    let dimensions: String?
    let fileSize: String?
    let mediaKind: MediaKind

    init(asset: Asset) {
        filename = asset.filename
        dateValue = AssetInfoFormatter.dateTaken(takenAt: asset.takenAt, addedAt: asset.addedAt)
        dateLabel = AssetInfoFormatter.dateTakenIsCaptureDate(takenAt: asset.takenAt) ? "Date Taken" : "Date Added"
        dimensions = AssetInfoFormatter.dimensions(width: asset.width, height: asset.height)
        fileSize = AssetInfoFormatter.fileSize(asset.fileSize)
        mediaKind = asset.mediaKind
    }
}
