import Foundation
import PhotosCore

/// Test-only compatibility shim for `Asset`.
///
/// The enriched `Asset` (see the bindings' EXIF/rating/description/video
/// metadata fields) added twelve required parameters to the generated
/// memberwise initializer with no defaults. Every fixture in this test target
/// builds assets through the pre-metadata 12-parameter shape, so this
/// convenience initializer reproduces exactly that signature and fills the new
/// fields with empty/zero defaults. That keeps the whole suite compiling
/// without rewriting each call site, and never touches the generated bindings.
///
/// A test that specifically needs a metadata field set can still call the full
/// generated initializer directly; this shim only covers the common
/// "identity + geometry" fixture case.
extension Asset {
    init(
        id: Int64,
        unitId: Int64,
        cacheKey: String,
        filename: String,
        mediaKind: MediaKind,
        takenAt: Int64?,
        addedAt: Int64?,
        width: UInt32?,
        height: UInt32?,
        fileSize: UInt64?,
        space: Space,
        serverVersion: Int64?
    ) {
        self.init(
            id: id,
            unitId: unitId,
            cacheKey: cacheKey,
            filename: filename,
            mediaKind: mediaKind,
            takenAt: takenAt,
            addedAt: addedAt,
            width: width,
            height: height,
            fileSize: fileSize,
            space: space,
            serverVersion: serverVersion,
            rating: 0,
            description: "",
            camera: "",
            aperture: "",
            exposureTime: "",
            focalLength: "",
            iso: "",
            lens: "",
            duration: "",
            framerate: "",
            videoCodec: "",
            containerType: "",
            latitude: nil,
            longitude: nil
        )
    }
}
