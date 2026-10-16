import Foundation
import ImageIO
import CoreGraphics

/// Off-main image decode. Callers must invoke from a background context;
/// ImageIO thumbnail decode does the heavy work without a full source decode.
enum ImageDownsample {
    private static func options(maxPixel: Int) -> CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
    }

    static func downsample(data: Data, maxPixel: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options(maxPixel: maxPixel))
    }

    static func downsample(fileURL: URL, maxPixel: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(fileURL as CFURL, srcOpts) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options(maxPixel: maxPixel))
    }
}
