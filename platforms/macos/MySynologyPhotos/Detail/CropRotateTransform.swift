import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Pure, view-free geometry for the non-destructive photo editor's crop and
/// rotate transform. Kept separate from any NSImage/SwiftUI code so the math
/// (output pixel dimensions for a rotation, a normalized crop resolved to an
/// integer pixel rect, and the two composed) is exhaustively unit-testable
/// without a real image on disk or a running app.
///
/// Conventions: rotation is measured in 90-degree CLOCKWISE quarter-turns; a
/// crop rectangle is NORMALIZED (each axis in 0...1) with a TOP-LEFT origin,
/// expressed in the ROTATED image's coordinate space (the space the editor's
/// crop overlay sits in). The full unit square means "no crop".
enum CropRotateMath {
    /// The whole image (no crop): the full unit square, top-left origin.
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Reduce an arbitrary (possibly negative or large) count of 90-degree
    /// steps to the canonical 0...3.
    static func normalizedSteps(_ steps: Int) -> Int {
        ((steps % 4) + 4) % 4
    }

    /// The PIXEL size of an image of `size` after `steps` quarter-turns. An odd
    /// number of turns swaps width and height; an even number leaves them.
    static func rotatedPixelSize(_ size: CGSize, steps: Int) -> CGSize {
        normalizedSteps(steps) % 2 == 0
            ? size
            : CGSize(width: size.height, height: size.width)
    }

    /// Resolve a normalized crop rectangle against a pixel `size` into an
    /// INTEGER pixel rect, clamped fully inside the image and never smaller
    /// than 1x1, so a degenerate or out-of-range crop can never produce an
    /// empty or out-of-bounds render rect. The returned origin is top-left,
    /// matching how the crop overlay is expressed in the UI.
    static func pixelCropRect(normalized rect: CGRect, in size: CGSize) -> CGRect {
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        // Clamp the normalized edges into the unit square first.
        let nMinX = min(max(rect.minX, 0), 1)
        let nMinY = min(max(rect.minY, 0), 1)
        let nMaxX = min(max(rect.maxX, 0), 1)
        let nMaxY = min(max(rect.maxY, 0), 1)

        var px = (nMinX * w).rounded(.down)
        var py = (nMinY * h).rounded(.down)
        var pw = ((nMaxX - nMinX) * w).rounded(.toNearestOrAwayFromZero)
        var ph = ((nMaxY - nMinY) * h).rounded(.toNearestOrAwayFromZero)
        pw = max(pw, 1)
        ph = max(ph, 1)
        // Keep the rect inside the image after rounding.
        px = max(min(px, w - pw), 0)
        py = max(min(py, h - ph), 0)
        return CGRect(x: px, y: py, width: pw, height: ph)
    }

    /// The final OUTPUT pixel size of a rotate-then-crop compose: rotate the
    /// input by `steps`, then apply `normalizedCrop` (in the rotated image's
    /// space). Equal to the pixel crop rect's size.
    static func outputPixelSize(inputSize: CGSize, steps: Int, normalizedCrop: CGRect) -> CGSize {
        let rotated = rotatedPixelSize(inputSize, steps: steps)
        return pixelCropRect(normalized: normalizedCrop, in: rotated).size
    }
}

/// Applies a `CropRotateMath` transform to real pixels: rotates a `CGImage` by
/// whole quarter-turns, crops it to a normalized rect, and encodes JPEG bytes.
///
/// NON-DESTRUCTIVE: this only ever produces a NEW image/`Data`. It never writes
/// back to any file or mutates its input; the caller uploads the returned bytes
/// as a brand-new asset (see `PhotoEditorModel`/`PhotosCore.save_edited_photo`).
enum PhotoTransformRenderer {
    /// Rotate `image` by `steps` clockwise quarter-turns. A zero (mod 4) turn
    /// returns the input unchanged. Renders into a fresh RGBA context sized to
    /// the rotated dimensions; returns nil only if that context cannot be made.
    static func rotate(_ image: CGImage, steps: Int) -> CGImage? {
        let n = CropRotateMath.normalizedSteps(steps)
        if n == 0 { return image }
        let w = image.width
        let h = image.height
        let outW = n % 2 == 0 ? w : h
        let outH = n % 2 == 0 ? h : w
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        // Rotate about the output center, then draw the source centered. The
        // CGContext origin is bottom-left, so a clockwise on-screen turn is a
        // negative angle here.
        ctx.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        ctx.rotate(by: -CGFloat(n) * (.pi / 2))
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// Rotate `image` by `steps` quarter-turns, then crop to `normalizedCrop`
    /// (expressed in the rotated image's space). Returns the resulting image.
    static func rotatedAndCropped(_ image: CGImage, steps: Int, normalizedCrop: CGRect) -> CGImage? {
        guard let rotated = rotate(image, steps: steps) else { return nil }
        let size = CGSize(width: rotated.width, height: rotated.height)
        let cropRect = CropRotateMath.pixelCropRect(normalized: normalizedCrop, in: size)
        // A full-square crop leaves the image as-is; skip the copy in that case.
        if cropRect == CGRect(origin: .zero, size: size) { return rotated }
        return rotated.cropping(to: cropRect) ?? rotated
    }

    /// Encode `image` as JPEG bytes. Returns nil if the destination could not
    /// be created or finalized.
    static func jpegData(from image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        let props = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The full rotate-then-crop-then-encode pipeline used by the editor's
    /// Save: returns JPEG bytes of the edited image, or nil on any step's
    /// failure.
    static func renderJPEG(from image: CGImage, steps: Int, normalizedCrop: CGRect, quality: CGFloat = 0.9) -> Data? {
        guard let out = rotatedAndCropped(image, steps: steps, normalizedCrop: normalizedCrop) else { return nil }
        return jpegData(from: out, quality: quality)
    }
}
