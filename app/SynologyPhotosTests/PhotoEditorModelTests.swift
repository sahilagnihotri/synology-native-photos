import Testing
import CoreGraphics
import Foundation
import PhotosCore
@testable import SynologyPhotos

/// Exercises the editor view-model's two safety-critical contracts against
/// `FakePhotosCore`: Save renders the edit and calls `saveEditedPhoto` with the
/// rendered bytes under a NEW `<base>-edited-<HHmmss>.jpg` filename, and Cancel
/// (and plain editing) never calls the core at all. The renderer is injected so
/// these assert on exact bytes without depending on real JPEG encoding.
@MainActor
struct PhotoEditorModelTests {
    private func makeImage(width: Int = 8, height: Int = 8) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    private func makeAsset(filename: String) -> Asset {
        Asset(
            id: 1, unitId: 10, cacheKey: "CK", filename: filename, mediaKind: .photo,
            takenAt: nil, addedAt: nil, width: 100, height: 60, fileSize: nil,
            space: .personal, serverVersion: nil)
    }

    private func makeModel(
        filename: String = "sunset.HEIC",
        render: @escaping (CGImage, Int, CGRect) -> Data? = { _, _, _ in Data([0x01, 0x02, 0x03]) }
    ) -> (PhotoEditorModel, FakePhotosCore) {
        let fake = FakePhotosCore()
        let model = PhotoEditorModel(
            asset: makeAsset(filename: filename),
            space: .personal,
            client: PhotosCoreClient(core: fake),
            render: render,
            now: { Date(timeIntervalSince1970: 0) })
        return (model, fake)
    }

    @Test func saveUploadsRenderedBytesUnderANewEditedFilename() async {
        let rendered = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let (model, fake) = makeModel(render: { _, _, _ in rendered })
        model.setSourceImage(makeImage())
        model.rotateRight()

        var refreshed = false
        await model.save { refreshed = true }

        #expect(fake.saveEditedPhotoCallCount == 1)
        #expect(fake.lastSaveEditedPhotoJpeg == rendered)
        // A NEW filename derived from the original, never the original itself.
        let name = fake.lastSaveEditedPhotoFilename
        #expect(name?.hasPrefix("sunset-edited-") == true)
        #expect(name?.hasSuffix(".jpg") == true)
        #expect(name != "sunset.HEIC")
        #expect(refreshed)
        #expect(model.state == .saved)
    }

    @Test func cancelMakesZeroCoreCalls() {
        let (model, fake) = makeModel()
        model.setSourceImage(makeImage())
        model.rotateRight()
        model.rotateLeft()
        model.cancel()
        #expect(fake.saveEditedPhotoCallCount == 0)
    }

    @Test func editingWithoutSavingMakesZeroCoreCalls() {
        // Loading the original and adjusting crop/rotation must never reach the
        // core: only an explicit Save uploads anything.
        let (model, fake) = makeModel()
        model.setSourceImage(makeImage())
        model.normalizedCrop = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        model.rotateRight()
        #expect(fake.saveEditedPhotoCallCount == 0)
    }

    @Test func saveWithoutALoadedImageMakesNoCoreCall() async {
        let (model, fake) = makeModel()
        // No setSourceImage → still loading.
        await model.save { }
        #expect(fake.saveEditedPhotoCallCount == 0)
    }

    @Test func saveSurfacesCoreErrorAndDoesNotRefresh() async {
        let (model, fake) = makeModel()
        fake.saveEditedPhotoResult = .failure(.Network(message: "dropped"))
        model.setSourceImage(makeImage())
        model.rotateRight()

        var refreshed = false
        await model.save { refreshed = true }

        #expect(fake.saveEditedPhotoCallCount == 1)
        #expect(!refreshed)
        if case .failed = model.state {} else {
            Issue.record("expected .failed state, got \(model.state)")
        }
    }

    @Test func hasEditsIsFalseUntilRotatedOrCropped() {
        let (model, _) = makeModel()
        model.setSourceImage(makeImage())
        #expect(!model.hasEdits)
        model.rotateRight()
        #expect(model.hasEdits)
        model.resetEdits()
        #expect(!model.hasEdits)
        model.normalizedCrop = CGRect(x: 0, y: 0, width: 0.5, height: 1)
        #expect(model.hasEdits)
    }

    @Test func editedFilenameStructureAndSanitization() {
        let name = PhotoEditorModel.editedFilename(originalFilename: "IMG_1234.JPG", date: Date(timeIntervalSince1970: 0))
        #expect(name.hasPrefix("IMG_1234-edited-"))
        #expect(name.hasSuffix(".jpg"))
        // The stamp between the prefix and ".jpg" is exactly six digits.
        let stamp = String(name.dropFirst("IMG_1234-edited-".count).dropLast(".jpg".count))
        #expect(stamp.count == 6)
        let allDigits = stamp.allSatisfy { $0.isNumber }
        #expect(allDigits)
        // An empty original name falls back to a safe placeholder base.
        let fallback = PhotoEditorModel.editedFilename(originalFilename: "", date: Date(timeIntervalSince1970: 0))
        #expect(fallback.hasPrefix("photo-edited-"))
    }
}
