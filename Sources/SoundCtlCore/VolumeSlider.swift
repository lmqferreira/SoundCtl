import AppKit

/// Custom slider cell that forges the native menu-bar Sound slider exactly:
/// a thin capsule track, an accent-blue fill, and a *borderless* white knob with
/// a soft shadow plus the subtle blue left-edge reflection while pressed. Native
/// mouse tracking is left untouched (we don't override the tracking loop), so the
/// drag stays smooth and never "sticks".
final class VolumeSliderCell: NSSliderCell {

    /// Track height (capsule thickness). Native is a thin hairline-ish bar.
    var trackThickness: CGFloat = 3
    /// Knob diameter (borderless white circle).
    var knobDiameter: CGFloat = 18

    private var pressed = false

    // MARK: Geometry

    override func barRect(flipped: Bool) -> NSRect {
        // Span the full control width, inset just enough for the knob to stay
        // inside, and collapse to the thin track height centered vertically.
        guard let view = controlView else { return super.barRect(flipped: flipped) }
        let bounds = view.bounds
        let inset = knobDiameter / 2
        return NSRect(x: bounds.minX + inset,
                      y: bounds.midY - trackThickness / 2,
                      width: bounds.width - knobDiameter,
                      height: trackThickness)
    }

    private func fraction() -> CGFloat {
        let span = maxValue - minValue
        guard span > 0 else { return 0 }
        return CGFloat((doubleValue - minValue) / span)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let bar = barRect(flipped: flipped)
        let x = bar.minX + fraction() * bar.width - knobDiameter / 2
        return NSRect(x: x, y: bar.midY - knobDiameter / 2,
                      width: knobDiameter, height: knobDiameter)
    }

    // MARK: Drawing

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let bar = barRect(flipped: flipped)
        let radius = bar.height / 2

        // Unfilled track: a soft translucent grey that reads correctly over the
        // glass. This portion does NOT change on press (only the blue does).
        let trackColor = NSColor.secondaryLabelColor.withAlphaComponent(0.28)
        let trackPath = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        trackColor.setFill()
        trackPath.fill()

        // Filled portion: accent blue up to the knob centre. Darken slightly while
        // pressed, matching the native behaviour.
        let center = bar.minX + fraction() * bar.width
        guard center > bar.minX else { return }
        var fillRect = bar
        fillRect.size.width = center - bar.minX
        let base = NSColor.controlAccentColor
        let fill = pressed
            ? (base.blended(withFraction: 0.18, of: .black) ?? base)
            : base
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: radius, yRadius: radius)
        fill.setFill()
        fillPath.fill()
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d = knobDiameter
        let rect = NSRect(x: knobRect.midX - d / 2, y: knobRect.midY - d / 2,
                          width: d, height: d).insetBy(dx: 0.5, dy: 0.5)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1.5
        shadow.set()

        let circle = NSBezierPath(ovalIn: rect)
        NSColor.white.setFill()
        circle.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Pressed: a faint blue reflection on the LEFT edge only (fades to clear
        // toward the centre) — never on the right.
        if pressed {
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            let blue = NSColor.controlAccentColor
            let gradient = NSGradient(colors: [blue.withAlphaComponent(0.28), blue.withAlphaComponent(0.0)])
            gradient?.draw(in: rect, angle: 0) // left → right, opaque at left
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Press state (native tracking is preserved; we only flag press)

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        pressed = true
        controlView.needsDisplay = true
        return super.startTracking(at: startPoint, in: controlView)
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint,
                               in controlView: NSView, mouseIsUp flag: Bool) {
        pressed = false
        controlView.needsDisplay = true
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
    }
}

/// Thin wrapper exposing the 0...1 API used by the view controller while driving
/// the custom cell above.
final class VolumeSlider: NSSlider {

    /// Called continuously while dragging with the new 0...1 value.
    var onChange: ((Float) -> Void)?

    /// Called with true when the user starts dragging, false when they release.
    var onEditingChanged: ((Bool) -> Void)?

    var value: Float {
        get { floatValue }
        set { floatValue = newValue }
    }

    var isEnabledControl: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }

    /// Retained for API compatibility; the level is shown by the fill directly.
    var isMutedLook: Bool = false

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let custom = VolumeSliderCell()
        custom.sliderType = .linear
        custom.minValue = 0
        custom.maxValue = 1
        custom.isContinuous = true
        cell = custom
        isContinuous = true
        target = self
        action = #selector(sliderChanged)
    }

    @objc private func sliderChanged() {
        onChange?(floatValue)
    }

    // NSSlider's own mouseDown runs the native tracking loop until mouse-up, so
    // drags don't get "stuck" when the pointer drifts vertically off the bar.
    override func mouseDown(with event: NSEvent) {
        onEditingChanged?(true)
        super.mouseDown(with: event)
        onEditingChanged?(false)
    }
}
