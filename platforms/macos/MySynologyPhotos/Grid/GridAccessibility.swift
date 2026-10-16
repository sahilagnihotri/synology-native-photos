import Foundation
import PhotosCore

/// Pure builders for the VoiceOver strings on the grid, kept free of AppKit
/// so they can be unit tested directly.
enum GridAccessibility {
    /// Label for a grid cell, e.g. "Photo, 25 November 2016, IMG_1234.jpg,
    /// selected". The date uses the same UTC calendar day the section header
    /// shows, so VoiceOver and the visible grouping agree. A missing date
    /// reads as "Unknown Date".
    static func cellLabel(asset: Asset, isSelected: Bool) -> String {
        let kind: String
        switch asset.mediaKind {
        case .photo: kind = "Photo"
        case .video: kind = "Video"
        case .unknown: kind = "Item"
        }
        var parts = [kind, DateSectionFormatter.headerTitle(dayStart: asset.takenAt ?? 0)]
        if !asset.filename.isEmpty { parts.append(asset.filename) }
        if isSelected { parts.append("selected") }
        return parts.joined(separator: ", ")
    }

    static let zoomSliderLabel = "Thumbnail size"

    /// Value description for the zoom slider as a percentage of its range,
    /// e.g. "50 percent". Out of range input is clamped.
    static func zoomSliderValue(itemSize: CGFloat, min: CGFloat, max: CGFloat) -> String {
        guard max > min else { return "0 percent" }
        let fraction = Swift.min(Swift.max((itemSize - min) / (max - min), 0), 1)
        return "\(Int((fraction * 100).rounded())) percent"
    }
}
