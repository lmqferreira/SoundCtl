import AppKit

/// Custom horizontal volume slider that mirrors the native Sound popover:
/// a thin rounded track, accent-coloured fill left of the knob, a white
/// circular knob with a soft shadow, and a disabled (all-grey) state.
final class VolumeSlider: NSControl {

    /// 0...1.
    var value: Float = 0 {
        didSet { value = max(0, min(1, value)); needsDisplay = true }
    }

    /// When false the control is greyed and ignores input (native behaviour
    /// for digital displays in Phase 1).
    var isEnabledControl: Bool = true {
        didSet { needsDisplay = true }
    }

    /// When true the fill is rendered grey instead of accent (muted look).
    var isMutedLook: Bool = false {
        didSet { needsDisplay = true }
    }

    /// Called continuously while dragging with the new 0...1 value.
    var onChange: ((Float) -> Void)?

    /// Called with true when the user starts dragging, false when they release.
    var onEditingChanged: ((Bool) -> Void)?

    private let trackHeight: CGFloat = 3
    private let knobWidth: CGFloat = 18
    private let knobHeight: CGFloat = 13
    private var dragging = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: knobHeight + 6)
    }

    override var isFlipped: Bool { false }

    // MARK: - Geometry

    private var trackRect: NSRect {
        let inset = knobWidth / 2
        return NSRect(x: inset,
                      y: (bounds.height - trackHeight) / 2,
                      width: bounds.width - knobWidth,
                      height: trackHeight)
    }

    private func knobCenterX(for value: Float) -> CGFloat {
        let t = trackRect
        return t.minX + CGFloat(value) * t.width
    }

    private func value(forX x: CGFloat) -> Float {
        let t = trackRect
        guard t.width > 0 else { return 0 }
        return Float(max(0, min(1, (x - t.minX) / t.width)))
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let t = trackRect
        let radius = trackHeight / 2

        // Track background.
        let bg = NSBezierPath(roundedRect: t, xRadius: radius, yRadius: radius)
        (isEnabledControl ? NSColor.tertiaryLabelColor : NSColor.quaternaryLabelColor)
            .setFill()
        bg.fill()

        // Fill left of knob.
        let cx = knobCenterX(for: value)
        let fillRect = NSRect(x: t.minX, y: t.minY, width: cx - t.minX, height: t.height)
        if fillRect.width > 0 {
            let fill = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
            let fillColor: NSColor
            if !isEnabledControl {
                fillColor = .tertiaryLabelColor
            } else if isMutedLook {
                fillColor = .secondaryLabelColor
            } else {
                fillColor = .controlAccentColor
            }
            fillColor.setFill()
            fill.fill()
        }

        // Knob: a horizontal pill (capsule), wider than tall — like native.
        let knobRect = NSRect(x: cx - knobWidth / 2,
                              y: (bounds.height - knobHeight) / 2,
                              width: knobWidth,
                              height: knobHeight)
        let knobRadius = knobHeight / 2
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let knobColor = isEnabledControl ? NSColor.white : NSColor(white: 0.85, alpha: 1)
        knobColor.setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: knobRadius, yRadius: knobRadius).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        NSColor.black.withAlphaComponent(0.08).setStroke()
        let ring = NSBezierPath(roundedRect: knobRect.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: knobRadius, yRadius: knobRadius)
        ring.lineWidth = 0.5
        ring.stroke()
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        guard isEnabledControl else { return }
        dragging = true
        onEditingChanged?(true)
        updateValue(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        updateValue(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        onEditingChanged?(false)
    }

    private func updateValue(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let v = value(forX: p.x)
        value = v
        onChange?(v)
    }
}
