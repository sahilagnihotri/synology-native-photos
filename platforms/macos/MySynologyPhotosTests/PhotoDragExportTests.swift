import Testing
import Foundation
import AppKit
import UniformTypeIdentifiers
import PhotosCore
@testable import MySynologyPhotos

/// Exercises the pure filename/type derivation and the promise fulfillment
/// behind dragging a photo or video out to Finder.
@MainActor
struct PhotoDragExportTests {
    private func asset(filename: String, mediaKind: MediaKind = .photo) -> Asset {
        Asset(id: 1, unitId: 42, cacheKey: "v1", filename: filename, mediaKind: mediaKind,
              takenAt: nil, addedAt: nil, width: nil, height: nil,
              fileSize: nil, space: .personal, serverVersion: 1)
    }

    // MARK: PhotoDragExport.fileType

    @Test func fileTypeDerivesFromARecognizedExtension() {
        let type = PhotoDragExport.fileType(for: asset(filename: "vacation.jpg"))
        #expect(type == UTType.jpeg.identifier)
    }

    @Test func fileTypeRecognizesHeicAndMov() {
        #expect(PhotoDragExport.fileType(for: asset(filename: "a.heic")) == UTType.heic.identifier)
        #expect(PhotoDragExport.fileType(for: asset(filename: "clip.mov", mediaKind: .video)) == UTType.quickTimeMovie.identifier)
    }

    @Test func fileTypeFallsBackToGenericDataForAnUnrecognizedExtension() {
        // "xyzabc" has no registered system UTI. UTType(filenameExtension:)
        // would otherwise hand back an opaque synthesized `dyn.*`
        // identifier for it; this normalizes that case to the standard
        // public.data identifier instead.
        let type = PhotoDragExport.fileType(for: asset(filename: "weird.xyzabc"))
        #expect(type == UTType.data.identifier)
    }

    @Test func fileTypeFallsBackWhenTheAssetsOwnFilenameHasNoExtensionAtAll() {
        // No extension at all: QuickLookFilename.derive supplies a
        // mediaKind-based fallback extension (jpg for photo), which IS
        // recognized, so this should resolve to jpeg, not the generic
        // data fallback.
        let type = PhotoDragExport.fileType(for: asset(filename: "noextension"))
        #expect(type == UTType.jpeg.identifier)
    }

    // MARK: PhotoExportPromiseDelegate.filePromiseProvider(fileNameForType:)

    @Test func delegateReportsTheDerivedFilename() {
        let fake = FakePhotosCore()
        let client = PhotosCoreClient(core: fake)
        let a = asset(filename: "sunset.jpg")
        let delegate = PhotoExportPromiseDelegate(asset: a, space: .personal, client: client)
        let provider = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)
        let name = delegate.filePromiseProvider(provider, fileNameForType: UTType.jpeg.identifier)
        #expect(name == "sunset.jpg")
    }

    // MARK: PhotoExportPromiseDelegate.writePromiseTo (the actual export)

    /// The core proof this feature exists for: fulfilling the promise
    /// downloads the ORIGINAL (via `downloadOriginal(unitId:)`, keyed on
    /// `unit_id` not `id`) and copies exactly those bytes to the
    /// destination URL Finder supplied, with no NAS mutation anywhere on
    /// the path.
    @Test func writePromiseCopiesTheDownloadedOriginalBytesToTheDestination() async throws {
        let fake = FakePhotosCore()
        let sourceDir = FileManager.default.temporaryDirectory.appendingPathComponent("export-src-\(UUID())")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let sourcePath = sourceDir.appendingPathComponent("syno-orig-abc").path
        let originalBytes = Data("this is the original file content".utf8)
        try originalBytes.write(to: URL(fileURLWithPath: sourcePath))
        defer { try? FileManager.default.removeItem(at: sourceDir) }

        fake.downloadResult = .success(sourcePath)
        let client = PhotosCoreClient(core: fake)
        let a = asset(filename: "sunset.jpg")
        let delegate = PhotoExportPromiseDelegate(asset: a, space: .personal, client: client)
        let provider = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("export-dest-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let error: Error? = try await withCheckedThrowingContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
                continuation.resume(returning: error)
            }
        }
        #expect(error == nil)
        let writtenBytes = try Data(contentsOf: destination)
        #expect(writtenBytes == originalBytes)

        // Confirms the download call itself was keyed correctly: unit_id
        // (42 in this fixture), never the asset's own id (1).
        #expect(fake.lastDownloadRequest?.unitId == 42)
        #expect(fake.downloadOriginalCallCount == 1)
    }

    @Test func writePromiseReportsAFailureWhenTheDownloadItselfFails() async throws {
        let fake = FakePhotosCore()
        fake.downloadResult = .failure(.Network(message: "offline"))
        let client = PhotosCoreClient(core: fake)
        let a = asset(filename: "sunset.jpg")
        let delegate = PhotoExportPromiseDelegate(asset: a, space: .personal, client: client)
        let provider = NSFilePromiseProvider(fileType: UTType.jpeg.identifier, delegate: delegate)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("export-fail-\(UUID()).jpg")
        defer { try? FileManager.default.removeItem(at: destination) }

        let error: Error? = try await withCheckedThrowingContinuation { continuation in
            delegate.filePromiseProvider(provider, writePromiseTo: destination) { error in
                continuation.resume(returning: error)
            }
        }
        #expect(error != nil)
        // Nothing must have been written to the destination on failure.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
