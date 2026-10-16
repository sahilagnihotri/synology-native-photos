import SwiftUI
import PhotosCore

/// Shown in place of the grid once the crawl barrier has flipped to complete
/// and the space genuinely has zero assets. Without this, a completed but
/// empty space renders as a blank black `NSCollectionView`, which looks
/// identical to a hang. This view exists so "done, and there is nothing
/// here" is visually distinct from "still working".
///
/// Styled after Apple Photos' own empty-library placeholder: a large muted
/// glyph, a short title, and a subtitle. The subtitle is space-aware: a user
/// whose Personal space is empty most likely has their photos in Shared, so
/// the hint points them there rather than leaving them wondering if the app
/// is broken.
struct EmptyLibraryView: View {
    let space: Space

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            Text("No Photos")
                .font(.title2)
                .fontWeight(.medium)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("library.empty")
        .accessibilityElement(children: .combine)
    }

    /// Points the user at the other space, since an empty result here does
    /// not mean the NAS has no photos at all, only that this particular
    /// space came back empty.
    private var subtitle: String {
        switch space {
        case .personal: return "No photos in your Personal space. Try the Shared tab."
        case .shared: return "No photos in your Shared space. Try the Personal tab."
        }
    }
}
