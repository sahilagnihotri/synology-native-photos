import Testing
import CoreGraphics
@testable import SynologyPhotos

/// Exercises the pure crop/rotate geometry and the real-pixel renderer that
/// backs the non-destructive editor. The math tests need no image at all; the
/// renderer tests build a tiny synthetic `CGImage` and assert on output
/// dimensions (the one property that pins "rotate swaps W/H", "crop shrinks to
/// the selected fraction", and the two composed).
struct CropRotateTransformTests {

    // MARK: - Pure math

    @Test func normalizedStepsWrapInBothDirections() {
        #expect(CropRotateMath.normalizedSteps(0) == 0)
        #expect(CropRotateMath.normalizedSteps(4) == 0)
        #expect(CropRotateMath.normalizedSteps(5) == 1)
        #expect(CropRotateMath.normalizedSteps(-1) == 3)
        #expect(CropRotateMath.normalizedSteps(-4) == 0)
    }

    @Test func rotatedPixelSizeSwapsOnOddTurns() {
        let size = CGSize(width: 100, height: 60)
        #expect(CropRotateMath.rotatedPixelSize(size, steps: 0) == CGSize(width: 100, height: 60))
        #expect(CropRotateMath.rotatedPixelSize(size, steps: 1) == CGSize(width: 60, height: 100))
        #expect(CropRotateMath.rotatedPixelSize(size, steps: 2) == CGSize(width: 100, height: 60))
        #expect(CropRotateMath.rotatedPixelSize(size, steps: 3) == CGSize(width: 60, height: 100))
    }

    @Test func fullCropResolvesToTheWholeImage() {
        let rect = CropRotateMath.pixelCropRect(normalized: CropRotateMath.fullCrop, in: CGSize(width: 100, height: 60))
        #expect(rect == CGRect(x: 0, y: 0, width: 100, height: 60))
    }

    @Test func normalizedCropResolvesToPixelRect() {
        // Right half of a 100x60 image → x:50 w:50, full height.
        let rect = CropRotateMath.pixelCropRect(
            normalized: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            in: CGSize(width: 100, height: 60))
        #expect(rect == CGRect(x: 50, y: 0, width: 50, height: 60))
    }

    @Test func cropRectClampsInBoundsAndNeverEmpty() {
        // A degenerate, out-of-range normalized rect must still resolve to a
        // >= 1px rect fully inside the image, never empty or out of bounds.
        let rect = CropRotateMath.pixelCropRect(
            normalized: CGRect(x: -1, y: -1, width: 0, height: 0),
            in: CGSize(width: 100, height: 60))
        #expect(rect.width >= 1)
        #expect(rect.height >= 1)
        #expect(rect.minX >= 0)
        #expect(rect.minY >= 0)
        #expect(rect.maxX <= 100)
        #expect(rect.maxY <= 60)
    }

    @Test func outputPixelSizeComposesRotateThenCrop() {
        // 100x60 rotated once → 60x100, cropped to the top half → 60x50.
        let out = CropRotateMath.outputPixelSize(
            inputSize: CGSize(width: 100, height: 60),
            steps: 1,
            normalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(out == CGSize(width: 60, height: 50))
    }

    // MARK: - Real-pixel renderer

    private func makeImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    @Test func rotateOnceSwapsRenderedDimensions() {
        let out = PhotoTransformRenderer.rotate(makeImage(width: 100, height: 60), steps: 1)!
        #expect(out.width == 60)
        #expect(out.height == 100)
    }

    @Test func cropLeftHalfWithoutRotation() {
        let out = PhotoTransformRenderer.rotatedAndCropped(
            makeImage(width: 100, height: 60), steps: 0,
            normalizedCrop: CGRect(x: 0, y: 0, width: 0.5, height: 1))!
        #expect(out.width == 50)
        #expect(out.height == 60)
    }

    @Test func rotateThenCropCompose() {
        // 100x60 rotated once → 60x100; crop top half of that → 60x50.
        let out = PhotoTransformRenderer.rotatedAndCropped(
            makeImage(width: 100, height: 60), steps: 1,
            normalizedCrop: CGRect(x: 0, y: 0, width: 1, height: 0.5))!
        #expect(out.width == 60)
        #expect(out.height == 50)
    }

    @Test func renderJPEGProducesDecodableBytesAtExpectedSize() {
        let data = PhotoTransformRenderer.renderJPEG(
            from: makeImage(width: 100, height: 60), steps: 1, normalizedCrop: CropRotateMath.fullCrop)!
        #expect(!data.isEmpty)
        let decoded = ImageDownsample.downsample(data: data, maxPixel: 4096)!
        #expect(decoded.width == 60)
        #expect(decoded.height == 100)
    }
}
