import SwiftUI
import PhotosCore

/// Banner shown while the initial crawl for a space is still running.
///
/// This is the visible half of the "never present partial as complete"
/// invariant: `PhotoGridController` is allowed to render whatever rows have
/// already loaded so scrolling is not blocked on the crawl finishing, but
/// as long as `CrawlProgressModel.isComplete` is false this banner stays on
/// screen so the library is never mistaken for a finished one. It
/// disappears entirely once the barrier flips to complete.
struct ImportProgressView: View {
    let model: CrawlProgressModel

    var body: some View {
        if !model.isComplete {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(model.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .accessibilityIdentifier("import.progress.banner")
            .accessibilityLabel(model.statusText)
        }
    }
}

/// Composes the grid with the importing banner above it. The grid always
/// reflects `WindowedDataSource`'s current resident rows regardless of
/// readiness (so a slow crawl does not block browsing what has already
/// loaded), but the banner is the caller-visible signal that the library is
/// still growing: it is driven by the same crawl barrier as
/// `WindowedDataSource.isReady`, never by comparing counts.
struct PhotoGridScreen: View {
    let controller: PhotoGridController
    let progress: CrawlProgressModel

    var body: some View {
        VStack(spacing: 0) {
            ImportProgressView(model: progress)
            PhotoGridView(controller: controller)
        }
    }
}
