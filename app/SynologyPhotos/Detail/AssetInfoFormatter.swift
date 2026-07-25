import Foundation
import PhotosCore

/// Pure display-string formatting behind the detail viewer's info panel,
/// kept free of SwiftUI so every field's exact text is directly testable
/// without a live view.
///
/// The panel mirrors Synology's own Information panel: the basics
/// (date/filename/dimensions/size) always, then a rating, an optional
/// caption, an EXIF group (camera/lens/aperture/exposure/focal/ISO), and a
/// video group (duration/frame rate/codec/container). The enriched `Asset`
/// carries all of these; the core reports an empty string for any text field
/// it has no value for (common on screenshots and scans) and `0` for an
/// unrated photo. This type turns each raw field into a display value or
/// `nil`, and the panel hides every `nil`/empty field entirely rather than
/// showing a blank row.
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

    /// Trims a raw NAS string field to a display value, or `nil` when it is
    /// empty. Empty string is the core's "not present" sentinel for the EXIF
    /// and video-metadata fields, so an empty value means the panel hides the
    /// row entirely instead of showing it blank.
    static func presentText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The 0..5 rating shown as a run of filled and empty stars, e.g.
    /// "★★★☆☆" for 3. Returns `nil` for an unrated asset (rating 0) so the
    /// row is hidden. Values outside 0..5 are clamped defensively rather
    /// than trusted, since the rating crosses the FFI boundary from an
    /// external system.
    static let maxStars = 5
    static func starRating(_ rating: Int32) -> String? {
        let filled = max(0, min(Int(rating), maxStars))
        guard filled > 0 else { return nil }
        return String(repeating: "★", count: filled)
            + String(repeating: "☆", count: maxStars - filled)
    }

    /// Formats a raw video duration (the NAS's `video_meta.duration`, a
    /// millisecond count carried as a string) as "m:ss", or "h:mm:ss" once
    /// past an hour. Returns `nil` for an empty or non-positive value so the
    /// row is hidden, and falls back to the trimmed raw string when the value
    /// is present but does not parse as a number, rather than dropping
    /// information the panel could still surface with its "Duration" label.
    static func videoDuration(_ raw: String) -> String? {
        guard let text = presentText(raw) else { return nil }
        guard let milliseconds = Double(text) else { return text }
        guard milliseconds > 0 else { return nil }
        let totalSeconds = Int((milliseconds / 1000).rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Formats a raw video frame rate (e.g. "29.97" or "50.0") rounded to a
    /// whole number with a " fps" suffix. Returns `nil` for an empty or
    /// non-positive value, and the trimmed raw string for a present but
    /// non-numeric value (same fail-open reasoning as `videoDuration`).
    static func videoFramerate(_ raw: String) -> String? {
        guard let text = presentText(raw) else { return nil }
        guard let value = Double(text) else { return text }
        guard value > 0 else { return nil }
        return "\(Int(value.rounded())) fps"
    }

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
///
/// Every optional field is `nil` exactly when the panel should hide it: an
/// empty EXIF/description string, an unrated photo, or a video-only field on
/// a non-video asset. The `has…` flags let the view decide whether to draw a
/// group's divider at all.
struct AssetInfoFields {
    let filename: String
    let dateLabel: String
    let dateValue: String
    let dimensions: String?
    let fileSize: String?
    let mediaKind: MediaKind

    let starRating: String?
    let description: String?

    // EXIF group.
    let camera: String?
    let lens: String?
    let aperture: String?
    let exposureTime: String?
    let focalLength: String?
    let iso: String?

    // Video group: populated only for `.video` assets, so a photo never
    // shows a "Duration" or "Codec" row even if some stray value slipped in.
    let duration: String?
    let framerate: String?
    let videoCodec: String?
    let containerType: String?

    /// Whether any EXIF field is present, so the view knows to draw the EXIF
    /// section (and its divider) at all.
    var hasExif: Bool {
        camera != nil || lens != nil || aperture != nil
            || exposureTime != nil || focalLength != nil || iso != nil
    }

    /// Whether any video-detail field is present.
    var hasVideoDetails: Bool {
        duration != nil || framerate != nil || videoCodec != nil || containerType != nil
    }

    init(asset: Asset) {
        filename = asset.filename
        dateValue = AssetInfoFormatter.dateTaken(takenAt: asset.takenAt, addedAt: asset.addedAt)
        dateLabel = AssetInfoFormatter.dateTakenIsCaptureDate(takenAt: asset.takenAt) ? "Date Taken" : "Date Added"
        dimensions = AssetInfoFormatter.dimensions(width: asset.width, height: asset.height)
        fileSize = AssetInfoFormatter.fileSize(asset.fileSize)
        mediaKind = asset.mediaKind

        starRating = AssetInfoFormatter.starRating(asset.rating)
        description = AssetInfoFormatter.presentText(asset.description)

        camera = AssetInfoFormatter.presentText(asset.camera)
        lens = AssetInfoFormatter.presentText(asset.lens)
        aperture = AssetInfoFormatter.presentText(asset.aperture)
        exposureTime = AssetInfoFormatter.presentText(asset.exposureTime)
        focalLength = AssetInfoFormatter.presentText(asset.focalLength)
        iso = AssetInfoFormatter.presentText(asset.iso)

        let isVideo = asset.mediaKind == .video
        duration = isVideo ? AssetInfoFormatter.videoDuration(asset.duration) : nil
        framerate = isVideo ? AssetInfoFormatter.videoFramerate(asset.framerate) : nil
        videoCodec = isVideo ? AssetInfoFormatter.presentText(asset.videoCodec) : nil
        containerType = isVideo ? AssetInfoFormatter.presentText(asset.containerType) : nil
    }
}
