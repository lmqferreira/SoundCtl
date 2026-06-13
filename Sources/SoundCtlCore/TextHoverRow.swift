import AppKit

/// A full-width row with a leading title and a hover highlight (used for the
/// "Sound Settings…" item). Click handling hit-tests bounds on mouse-up rather
/// than gating on hover, so it works inside a non-activating panel.
final class TextHoverRow: NSView {
    private let label = NSTextField(labelWithString: "")
    private let highlight = NSView()
    let action: () -> Void
    private var trackingArea: NSTrackingArea?

    init(title: String, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        addSubview(highlight)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.stringValue = title
        addSubview(label)

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func setHovered(_ hovered: Bool) {
        highlight.layer?.backgroundColor = hovered
            ? NSColor(white: 0.5, alpha: 0.22).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }

    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    func handleMouseUp(atLocalPoint point: NSPoint) {
        if bounds.contains(point) { action() }
    }
}
