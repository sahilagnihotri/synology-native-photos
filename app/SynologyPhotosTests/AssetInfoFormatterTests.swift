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

    /// Builds an asset with the enriched metadata fields set, via the full
    /// generated initializer (the test-target shim only covers the
    /// identity+geometry shape). Every metadata field defaults to the core's
    /// "not present" sentinel (empty string / rating 0).
    private func metaAsset(
        filename: String = "IMG_0001.heic",
        mediaKind: MediaKind = .photo,
        takenAt: Int64? = nil, addedAt: Int64? = nil,
        width: UInt32? = nil, height: UInt32? = nil, fileSize: UInt64? = nil,
        rating: Int32 = 0, description: String = "",
        camera: String = "", aperture: String = "", exposureTime: String = "",
        focalLength: String = "", iso: String = "", lens: String = "",
        duration: String = "", framerate: String = "",
        videoCodec: String = "", containerType: String = ""
    ) -> Asset {
        Asset(id: 1, unitId: 1, cacheKey: "v", filename: filename, mediaKind: mediaKind,
              takenAt: takenAt, addedAt: addedAt, width: width, height: height,
              fileSize: fileSize, space: .personal, serverVersion: 1,
              rating: rating, description: description, camera: camera,
              aperture: aperture, exposureTime: exposureTime, focalLength: focalLength,
              iso: iso, lens: lens, duration: duration, framerate: framerate,
              videoCodec: videoCodec, containerType: containerType)
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

    // MARK: presentText (empty-field hiding)

    @Test func presentTextReturnsTrimmedValueWhenPresent() {
        #expect(AssetInfoFormatter.presentText("  Apple iPhone 12  ") == "Apple iPhone 12")
    }

    @Test func presentTextReturnsNilForEmptyOrWhitespaceOnly() {
        #expect(AssetInfoFormatter.presentText("") == nil)
        #expect(AssetInfoFormatter.presentText("   ") == nil)
        #expect(AssetInfoFormatter.presentText("\n\t") == nil)
    }

    // MARK: starRating

    @Test func starRatingRendersFilledAndEmptyStars() {
        #expect(AssetInfoFormatter.starRating(3) == "★★★☆☆")
        #expect(AssetInfoFormatter.starRating(5) == "★★★★★")
        #expect(AssetInfoFormatter.starRating(1) == "★☆☆☆☆")
    }

    @Test func starRatingIsNilForUnrated() {
        // Rating 0 means unrated: the row is hidden entirely.
        #expect(AssetInfoFormatter.starRating(0) == nil)
    }

    @Test func starRatingClampsOutOfRangeValues() {
        // Values crossing the FFI boundary are not trusted: a negative
        // rating is treated as unrated, an over-max rating as full.
        #expect(AssetInfoFormatter.starRating(-2) == nil)
        #expect(AssetInfoFormatter.starRating(9) == "★★★★★")
    }

    // MARK: videoDuration

    @Test func videoDurationFormatsMillisecondsAsMinutesSeconds() {
        // The NAS reports duration in milliseconds; 2000 ms is a 2 second clip.
        #expect(AssetInfoFormatter.videoDuration("2000") == "0:02")
        #expect(AssetInfoFormatter.videoDuration("125000") == "2:05")
    }

    @Test func videoDurationFormatsHoursWhenPastAnHour() {
        #expect(AssetInfoFormatter.videoDuration("3661000") == "1:01:01")
    }

    @Test func videoDurationParsesADecimalMillisecondValue() {
        #expect(AssetInfoFormatter.videoDuration("2000.0") == "0:02")
    }

    @Test func videoDurationIsNilForEmptyOrNonPositive() {
        #expect(AssetInfoFormatter.videoDuration("") == nil)
        #expect(AssetInfoFormatter.videoDuration("   ") == nil)
        #expect(AssetInfoFormatter.videoDuration("0") == nil)
    }

    @Test func videoDurationFallsBackToRawStringWhenNotANumber() {
        // A present-but-unparseable value is still information: show it raw
        // rather than dropping the row.
        #expect(AssetInfoFormatter.videoDuration("PT2S") == "PT2S")
    }

    // MARK: videoFramerate

    @Test func videoFramerateRoundsAndSuffixesFps() {
        #expect(AssetInfoFormatter.videoFramerate("50.0") == "50 fps")
        #expect(AssetInfoFormatter.videoFramerate("29.97") == "30 fps")
        #expect(AssetInfoFormatter.videoFramerate("24") == "24 fps")
    }

    @Test func videoFramerateIsNilForEmptyOrNonPositive() {
        #expect(AssetInfoFormatter.videoFramerate("") == nil)
        #expect(AssetInfoFormatter.videoFramerate("0") == nil)
    }

    @Test func videoFramerateFallsBackToRawStringWhenNotANumber() {
        #expect(AssetInfoFormatter.videoFramerate("variable") == "variable")
    }

    // MARK: AssetInfoFields metadata (rating / EXIF / description)

    @Test func fieldsExposesStarsForARatedAssetAndNilForUnrated() {
        #expect(AssetInfoFields(asset: metaAsset(rating: 4)).starRating == "★★★★☆")
        #expect(AssetInfoFields(asset: metaAsset(rating: 0)).starRating == nil)
    }

    @Test func fieldsCarriesExifWhenPresentAndHidesEmptyOnes() {
        let fields = AssetInfoFields(asset: metaAsset(
            camera: "Apple iPhone 12", aperture: "f/1.8", exposureTime: "1/120",
            focalLength: "26 mm", iso: "100", lens: ""))
        #expect(fields.camera == "Apple iPhone 12")
        #expect(fields.aperture == "f/1.8")
        #expect(fields.exposureTime == "1/120")
        #expect(fields.focalLength == "26 mm")
        #expect(fields.iso == "100")
        // Empty lens is hidden, not shown blank.
        #expect(fields.lens == nil)
        #expect(fields.hasExif == true)
    }

    @Test func fieldsHasNoExifWhenEveryExifFieldIsEmpty() {
        // A screenshot or scan carries no EXIF at all: the whole group hides.
        let fields = AssetInfoFields(asset: metaAsset())
        #expect(fields.hasExif == false)
        #expect(fields.camera == nil)
    }

    @Test func fieldsCarriesDescriptionOnlyWhenNonEmpty() {
        #expect(AssetInfoFields(asset: metaAsset(description: "Sunset")).description == "Sunset")
        #expect(AssetInfoFields(asset: metaAsset(description: "")).description == nil)
    }

    // MARK: AssetInfoFields video group

    @Test func fieldsPopulatesVideoGroupForAVideoAsset() {
        let fields = AssetInfoFields(asset: metaAsset(
            mediaKind: .video, duration: "2000", framerate: "50.0",
            videoCodec: "hevc", containerType: "mov"))
        #expect(fields.duration == "0:02")
        #expect(fields.framerate == "50 fps")
        #expect(fields.videoCodec == "hevc")
        #expect(fields.containerType == "mov")
        #expect(fields.hasVideoDetails == true)
    }

    @Test func fieldsHidesVideoGroupForANonVideoAsset() {
        // Even if some stray video field slipped onto a photo, a non-video
        // asset never shows a Duration/Codec row.
        let fields = AssetInfoFields(asset: metaAsset(
            mediaKind: .photo, duration: "2000", framerate: "50.0",
            videoCodec: "hevc", containerType: "mov"))
        #expect(fields.duration == nil)
        #expect(fields.framerate == nil)
        #expect(fields.videoCodec == nil)
        #expect(fields.containerType == nil)
        #expect(fields.hasVideoDetails == false)
    }
}
