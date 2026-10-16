import AppKit

/// A small floating date indicator ("2016 / 11") that appears near the right
/// scroll edge of the library grid while it scrolls and fades out when
/// scrolling stops, matching Synology's date scrubber.
///
/// Read-only in this pass: it names the date of the topmost visible cell but
/// does not itself drive scrolling. Drag-to-jump (grab the indicator to scroll
/// to a date) is a deliberate follow-up; the geometry it would need
/// (`GridDateSections` prefix sums, already unit-tested) is in place.
final class DateScrubberView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        background.translatesAutoresizingMaskIntoConstraints = false
        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 7
        background.layer?.masksToBounds = true
        addSubview(background)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(label)

        // The label's trailing/bottom insets are the ones that define the
        // view's size (leading/top only pin its origin). This view is a
        // frame-positioned floating overlay, so it exists at a 0x0 frame for a
        // beat before it is sized, during which those two required insets can't
        // fit and AppKit logs a constraint conflict against the autoresizing
        // width==0/height==0. Making just those two non-required lets AppKit
        // yield them silently during that transient; once the real frame lands
        // the label sits at its full 10/5 insets exactly as before.
        let trailingInset = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        let bottomInset = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
        trailingInset.priority = .defaultHigh
        bottomInset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            trailingInset,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            bottomInset,
        ])
        setAccessibilityIdentifier("grid.scrubber")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    func setText(_ text: String) { label.stringValue = text }
}
