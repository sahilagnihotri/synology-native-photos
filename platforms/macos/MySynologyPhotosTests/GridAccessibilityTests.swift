import Testing
import PhotosCore
@testable import MySynologyPhotos

struct GridAccessibilityTests {
    private func asset(kind: MediaKind, takenAt: Int64?, filename: String = "IMG_1234.jpg") -> Asset {
        Asset(id: 1, unitId: 1, cacheKey: "k", filename: filename, mediaKind: kind,
              takenAt: takenAt, addedAt: nil, width: nil, height: nil, fileSize: nil,
              space: .personal, serverVersion: nil)
    }

    // 2016-11-25 12:00:00 UTC
    private let nov25: Int64 = 1_480_075_200

    @Test func photoLabelHasKindDateAndFilename() {
        #expect(GridAccessibility.cellLabel(asset: asset(kind: .photo, takenAt: nov25), isSelected: false)
                == "Photo, 25 November 2016, IMG_1234.jpg")
    }

    @Test func videoLabelSaysVideo() {
        #expect(GridAccessibility.cellLabel(asset: asset(kind: .video, takenAt: nov25), isSelected: false)
                .hasPrefix("Video, "))
    }

    @Test func selectedStateIsAppended() {
        #expect(GridAccessibility.cellLabel(asset: asset(kind: .photo, takenAt: nov25), isSelected: true)
                .hasSuffix(", selected"))
    }

    @Test func missingDateReadsUnknownDate() {
        #expect(GridAccessibility.cellLabel(asset: asset(kind: .photo, takenAt: nil), isSelected: false)
                == "Photo, Unknown Date, IMG_1234.jpg")
    }

    @Test func emptyFilenameIsOmitted() {
        #expect(GridAccessibility.cellLabel(asset: asset(kind: .photo, takenAt: nov25, filename: ""), isSelected: false)
                == "Photo, 25 November 2016")
    }

    @Test func zoomValueIsPercentOfRangeAndClamped() {
        #expect(GridAccessibility.zoomSliderValue(itemSize: 60, min: 60, max: 320) == "0 percent")
        #expect(GridAccessibility.zoomSliderValue(itemSize: 190, min: 60, max: 320) == "50 percent")
        #expect(GridAccessibility.zoomSliderValue(itemSize: 999, min: 60, max: 320) == "100 percent")
    }
}
