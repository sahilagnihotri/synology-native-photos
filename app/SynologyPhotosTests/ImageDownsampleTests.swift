import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SynologyPhotos

struct ImageDownsampleTests {
    private func makePNG(width: Int, height: Int) -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func downsamplesToRequestedMaxPixel() throws {
        let data = makePNG(width: 800, height: 600)
        let img = try #require(ImageDownsample.downsample(data: data, maxPixel: 240))
        #expect(max(img.width, img.height) <= 240)
        #expect(img.width > 0 && img.height > 0)
    }

    @Test func downsampleFromFileURL() throws {
        let data = makePNG(width: 1000, height: 400)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID()).png")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let img = try #require(ImageDownsample.downsample(fileURL: url, maxPixel: 320))
        #expect(max(img.width, img.height) <= 320)
    }

    @Test func garbageDataReturnsNil() {
        #expect(ImageDownsample.downsample(data: Data([0, 1, 2, 3]), maxPixel: 100) == nil)
    }
}
