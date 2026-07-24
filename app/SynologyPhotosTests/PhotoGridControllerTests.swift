import Testing
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotosCore
@testable import SynologyPhotos

@MainActor
struct PhotoGridControllerTests {
    private func asset(_ id: Int64) -> Asset {
        Asset(id: id, cacheKey: "v", filename: "\(id).jpg", mediaKind: .photo,
              takenAt: 1_700_000_000 + id, addedAt: nil, width: 100, height: 100,
              fileSize: nil, space: .personal, serverVersion: id)
    }

    /// Writes a solid-color PNG with a distinct aspect ratio so a decoded
    /// thumbnail can be told apart from another asset's without comparing
    /// raw pixels: after `ThumbnailCache` downsamples to a `.sm` (240px)
    /// bound, the wide/tall ratio survives even though absolute pixel
    /// dimensions do not.
    private func writePNG(width: Int, height: Int) -> String {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cell-\(UUID()).png")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return url.path
    }

    @Test func snapshotReflectsLoadedWindow() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<120).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 120, total: 120, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 60)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache)
        _ = controller.view
        await ds.refreshCount()
        await ds.loadWindow(offset: 0, limit: 60)
        await controller.applySnapshot()
        // One item identifier per index across the whole space (120), not
        // per loaded window (60): the placeholder-id strategy keeps the
        // snapshot count equal to totalCount so scrollbar geometry is
        // correct as soon as the count is known, regardless of how much of
        // the window has actually loaded.
        #expect(controller.snapshotItemCount() == 120)
    }

    @Test func cellConfigureDoesNotCrashWithoutImage() {
        let cell = PhotoCellView()
        _ = cell.view
        let cache = ThumbnailCache(client: PhotosCoreClient(core: FakePhotosCore()))
        cell.configure(asset: asset(1), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 1)
    }

    /// `totalCount` reflects the full space size even before every row has
    /// been paged in; only `loadWindow` populates `resident` rows.
    @Test func snapshotCountMatchesTotalCountBeforeAnyWindowLoads() async {
        let fake = FakePhotosCore()
        fake.assets[.personal] = (0..<500).map { asset(Int64($0)) }
        fake.progressBySpace[.personal] = CrawlProgress(space: .personal, done: 500, total: 500, complete: true)
        let client = PhotosCoreClient(core: fake)
        let ds = WindowedDataSource(client: client, space: .personal, pageSize: 50)
        let cache = ThumbnailCache(client: client)
        let controller = PhotoGridController(dataSource: ds, cache: cache)
        _ = controller.view
        await ds.refreshCount()
        await controller.applySnapshot()
        #expect(controller.snapshotItemCount() == 500)
    }

    /// The classic grid-reuse bug: a cell configured for asset A, then
    /// reused for asset B before A's thumbnail load resolves, must not
    /// paint A's late-arriving image over B.
    ///
    /// This forces the actual race rather than hoping for one: asset A's
    /// fake thumbnail load is held up by an artificial delay, so it is
    /// provably still in flight at the moment the cell is reused for asset
    /// B (whose load has no delay and resolves immediately). Only after B's
    /// image has been painted does the test wait for A's delayed load to
    /// finally resolve, then asserts A's image never overwrote B's. A and B
    /// use images with different aspect ratios so the assertion is on the
    /// actual painted pixels, not just on `representedAssetId` (which the
    /// guard's completion closure never touches, so it alone would not
    /// catch a broken guard).
    ///
    /// Without the `representedAssetId == targetId` recheck in
    /// `PhotoCellView.configure`'s completion, A's delayed load would
    /// unconditionally paint into `thumbView` after B's fast load already
    /// painted B's image, and this test would fail: it was run once with
    /// that guard line commented out to confirm the failure, then restored.
    @Test func prepareForReuseDropsStaleLoadThatResolvesAfterReuse() async throws {
        let fake = FakePhotosCore()
        let widePath = writePNG(width: 800, height: 200) // asset A: 4:1
        let squarePath = writePNG(width: 400, height: 400) // asset B: 1:1
        defer {
            try? FileManager.default.removeItem(atPath: widePath)
            try? FileManager.default.removeItem(atPath: squarePath)
        }

        let cache = ThumbnailCache(client: PhotosCoreClient(core: fake))
        let cell = PhotoCellView()
        _ = cell.view

        // Asset A's load is held up well past the point where the test will
        // have already reused the cell for B and let B's load resolve.
        // Results are keyed by asset id (not the shared `thumbnailResult`)
        // so A's call still resolves to A's own wide image after it wakes,
        // even though B's result is assigned in the meantime.
        fake.thumbnailDelayByAssetId[1] = .milliseconds(150)
        fake.thumbnailResultByAssetId[1] = .success(ThumbnailData(cachedPath: widePath, bytes: Data()))
        cell.configure(asset: asset(1), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 1)

        // Give asset A's task a chance to start (and reach the `await` on
        // the artificial delay) without giving it anywhere near enough time
        // to finish; this is what makes the reuse below land while A is
        // still genuinely in flight, unlike a bare `Task.yield()`.
        try await Task.sleep(for: .milliseconds(20))

        // Simulate the collection view recycling this cell for a different
        // index before asset 1's async load has resolved.
        cell.prepareForReuse()
        #expect(cell.representedAssetId == -1)
        #expect(cell.displayedImage == nil)

        // Asset B has no delay, so its load resolves and paints almost
        // immediately.
        fake.thumbnailResultByAssetId[2] = .success(ThumbnailData(cachedPath: squarePath, bytes: Data()))
        cell.configure(asset: asset(2), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 2)

        try await Task.sleep(for: .milliseconds(60))
        let afterB = try #require(cell.displayedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(afterB.width == afterB.height) // B's square aspect ratio, not A's 4:1.

        // Now let asset A's delayed load actually resolve. Its guard check
        // (representedAssetId == 1) must fail since the cell now reads 2,
        // so the wide image must never land, and B's square image must
        // still be the one displayed.
        try await Task.sleep(for: .milliseconds(150))
        #expect(cell.representedAssetId == 2)
        let final = try #require(cell.displayedImage?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(final.width == final.height)
    }

    /// Re-`configure`-ing the same cell in place (no `prepareForReuse` in
    /// between, e.g. a reconfigure from a diffable snapshot apply) must
    /// still cancel the previous load rather than racing two loads against
    /// one image view.
    @Test func reconfiguringInPlaceReplacesRepresentedId() {
        let cache = ThumbnailCache(client: PhotosCoreClient(core: FakePhotosCore()))
        let cell = PhotoCellView()
        _ = cell.view

        cell.configure(asset: asset(10), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 10)

        cell.configure(asset: asset(11), space: .personal, cache: cache)
        #expect(cell.representedAssetId == 11)
    }
}
