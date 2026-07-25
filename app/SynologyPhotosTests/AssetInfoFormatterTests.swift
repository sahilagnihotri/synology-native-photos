import Testing
import PhotosCore
@testable import SynologyPhotos

/// Exercises the pure display-string formatting behind the detail viewer's
/// info panel, independent of any SwiftUI view.
struct AssetInfoFormatterTests {
    private func asset(
        takenAt: Int64? = nil, addedAt: Int64? = nil,
        width: UInt32? = nil, height: UInt32? = nil,
        fileSize: UInt64? = nil, filename: String = "IMG_0001.heic",
        mediaKind: MediaKind = .photo
    ) -> Asset {
        Asset(id: 1, unitId: 1, cacheKey: "v", filename: filename, mediaKind: mediaKind,
              takenAt: takenAt, addedAt: addedAt, width: width, height: height,
              fileSize: fileSize, space: .personal, serverVersion: 1)
    }

    // MARK: dateTaken

    @Test func dateTakenUsesTakenAtWhenPresent() {
        // 1_700_000_000 is a fixed, well past epoch timestamp so this does
        // not depend on "now"; only that some non-empty, non-placeholder
        // string comes back.
        let text = AssetInfoFormatter.dateTaken(takenAt: 1_700_000_000, addedAt: 1_600_000_000)
        #expect(text != "Unknown")
        #expect(!text.isEmpty)
    }

    @Test func dateTakenFallsBackToAddedAtWhenTakenAtIsNil() {
        let text = AssetInfoFormatter.dateTaken(takenAt: nil, addedAt: 1_600_000_000)
        #expect(text != "Unknown")
    }

    @Test func dateTakenIsUnknownWhenNeitherIsAvailable() {
        #expect(AssetInfoFormatter.dateTaken(takenAt: nil, addedAt: nil) == "Unknown")
    }

    @Test func dateTakenIsCaptureDateOnlyWhenTakenAtItselfIsPresent() {
        #expect(AssetInfoFormatter.dateTakenIsCaptureDate(takenAt: 1_700_000_000) == true)
        #expect(AssetInfoFormatter.dateTakenIsCaptureDate(takenAt: nil) == false)
    }

    // MARK: dimensions

    @Test func dimensionsFormatsBothValuesWithASpacedX() {
        #expect(AssetInfoFormatter.dimensions(width: 1920, height: 1080) == "1920 x 1080")
    }

    @Test func dimensionsIsNilWhenEitherValueIsMissing() {
        #expect(AssetInfoFormatter.dimensions(width: nil, height: 1080) == nil)
        #expect(AssetInfoFormatter.dimensions(width: 1920, height: nil) == nil)
        #expect(AssetInfoFormatter.dimensions(width: nil, height: nil) == nil)
    }

    @Test func dimensionsIsNilWhenEitherValueIsZero() {
        // A zero dimension is not a real width/height the NAS actually
        // measured; treat it the same as missing rather than showing
        // "0 x 1080".
        #expect(AssetInfoFormatter.dimensions(width: 0, height: 1080) == nil)
        #expect(AssetInfoFormatter.dimensions(width: 1920, height: 0) == nil)
    }

    // MARK: fileSize

    @Test func fileSizeFormatsANonZeroByteCount() {
        let text = AssetInfoFormatter.fileSize(2_400_000)
        #expect(text != nil)
        #expect(!(text ?? "").isEmpty)
    }

    @Test func fileSizeIsNilWhenMissingOrZero() {
        #expect(AssetInfoFormatter.fileSize(nil) == nil)
        #expect(AssetInfoFormatter.fileSize(0) == nil)
    }

    // MARK: AssetInfoFields (the bundled, Asset-derived struct)

    @Test func fieldsCarriesFilenameDirectlyFromTheAsset() {
        let fields = AssetInfoFields(asset: asset(filename: "vacation.jpg"))
        #expect(fields.filename == "vacation.jpg")
    }

    @Test func fieldsLabelsDateAsTakenWhenCaptureDateIsKnown() {
        let fields = AssetInfoFields(asset: asset(takenAt: 1_700_000_000, addedAt: 1_600_000_000))
        #expect(fields.dateLabel == "Date Taken")
    }

    @Test func fieldsLabelsDateAsAddedWhenOnlyImportDateIsKnown() {
        let fields = AssetInfoFields(asset: asset(takenAt: nil, addedAt: 1_600_000_000))
        #expect(fields.dateLabel == "Date Added")
    }

    @Test func fieldsCarriesDimensionsAndFileSizeWhenAvailable() {
        let fields = AssetInfoFields(asset: asset(width: 4000, height: 3000, fileSize: 5_000_000))
        #expect(fields.dimensions == "4000 x 3000")
        #expect(fields.fileSize != nil)
    }

    @Test func fieldsLeavesDimensionsAndFileSizeNilWhenTheAssetHasNone() {
        let fields = AssetInfoFields(asset: asset())
        #expect(fields.dimensions == nil)
        #expect(fields.fileSize == nil)
    }

    @Test func fieldsCarriesMediaKindFromTheAsset() {
        let fields = AssetInfoFields(asset: asset(mediaKind: .video))
        #expect(fields.mediaKind == .video)
    }

    // MARK: exifFollowUpNote

    @Test func exifFollowUpNoteIsAFixedHonestString() {
        // Not empty, and not something that could be mistaken for a real
        // EXIF value; this guards against ever accidentally shipping a
        // blank or a fabricated placeholder here.
        #expect(!AssetInfoFormatter.exifFollowUpNote.isEmpty)
        #expect(AssetInfoFormatter.exifFollowUpNote.lowercased().contains("not available"))
    }
}
