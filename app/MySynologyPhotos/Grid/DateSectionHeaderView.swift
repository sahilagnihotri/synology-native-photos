import AppKit

/// A pinned section header for the date-grouped library grid: a single
/// left-aligned date label (e.g. "25 November 2016") over a subtle material
/// backing so it stays legible while it floats over scrolling thumbnails.
///
/// Plain and legible, matching Photos' own day headers. It shows the date
/// only: there is no per-item location/geocoding data available to this grid,
/// so a "place" line would be either blank or wrong. Reused across sections by
/// the collection view, so `configure(title:)` is the only mutable state.
final class DateSectionHeaderView: NSView, NSCollectionViewElement {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("DateSectionHeaderView")

    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        addSubview(background)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func configure(title: String) {
        label.stringValue = title
        setAccessibilityIdentifier("grid.section.header")
    }
}
