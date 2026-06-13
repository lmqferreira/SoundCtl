import AppKit
import CoreAudio

/// A single row in the Output list: circular device glyph (accent-filled when
/// selected, grey otherwise) + name label, with a translucent rounded hover
/// highlight matching the native popover.
final class OutputDeviceRow: NSView {

    var onClick: (() -> Void)?
    let deviceID: AudioDeviceID

    private let iconContainer = NSView()
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let highlight = NSView()

    private var hovering = false
    private var trackingArea: NSTrackingArea?

    private let circleDiameter: CGFloat = 26

    init(deviceID: AudioDeviceID, symbol: String, name: String, selected: Bool) {
        self.deviceID = deviceID
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        highlight.translatesAutoresizingMaskIntoConstraints = false
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 6
        highlight.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(highlight)

        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.wantsLayer = true
        iconContainer.layer?.cornerRadius = circleDiameter / 2
        addSubview(iconContainer)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconContainer.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .labelColor
        label.stringValue = name
        addSubview(label)

        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            highlight.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),

            iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconContainer.widthAnchor.constraint(equalToConstant: circleDiameter),
            iconContainer.heightAnchor.constraint(equalToConstant: circleDiameter),

            iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            label.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            heightAnchor.constraint(equalToConstant: 32)
        ])

        configure(symbol: symbol, selected: selected)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure(symbol: String, selected: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        setSelected(selected)
    }

    func setSelected(_ selected: Bool) {
        if selected {
            iconContainer.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            iconView.contentTintColor = .white
        } else {
            iconContainer.layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.25).cgColor
            iconView.contentTintColor = .labelColor
        }
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // .activeAlways so hover/click tracking works even though the hosting
        // panel is a non-activating accessory window.
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func setHovered(_ hovered: Bool) {
        hovering = hovered
        highlight.layer?.backgroundColor = hovered
            ? NSColor(white: 0.5, alpha: 0.22).cgColor
            : NSColor.clear.cgColor
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }

    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        handleMouseUp(atLocalPoint: convert(event.locationInWindow, from: nil))
    }

    /// Registers a click when the mouse-up lands inside the row. Not gated on
    /// hover state (which can be unreliable in a non-activating panel).
    func handleMouseUp(atLocalPoint point: NSPoint) {
        if bounds.contains(point) { onClick?() }
    }
}
