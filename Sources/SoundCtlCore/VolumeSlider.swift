import AppKit

/// A thin wrapper over the standard `NSSlider` so the OS renders the exact
/// native slider — track, accent fill, translucent knob with the blue "press"
/// reflection, the fill-darkens-on-press behaviour, and smooth drag tracking
/// (the same control used throughout System Settings). Hand-drawing these was a
/// mistake; the system owns them.
final class VolumeSlider: NSSlider {

    /// Called continuously while dragging with the new 0...1 value.
    var onChange: ((Float) -> Void)?

    /// Called with true when the user starts dragging, false when they release.
    var onEditingChanged: ((Bool) -> Void)?

    /// 0...1 convenience accessors (keep the previous call sites working).
    var value: Float {
        get { floatValue }
        set { floatValue = newValue }
    }

    var isEnabledControl: Bool {
        get { isEnabled }
        set { isEnabled = newValue }
    }

    /// Retained for API compatibility; the native slider shows the level
    /// directly, so a separate "muted look" isn't needed.
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
        sliderType = .linear
        minValue = 0
        maxValue = 1
        isContinuous = true
        // The OS renders the accent-coloured fill (with the native press states
        // and translucent knob reflection) when a track fill colour is set.
        trackFillColor = .controlAccentColor
        target = self
        action = #selector(sliderChanged)
    }

    @objc private func sliderChanged() {
        onChange?(floatValue)
    }

    // NSSlider's mouseDown runs its own tracking loop until mouse-up, so we get
    // clean drag start/end bracketing and native (capture-the-mouse) tracking
    // that doesn't get "stuck" when the pointer moves vertically off the slider.
    override func mouseDown(with event: NSEvent) {
        onEditingChanged?(true)
        super.mouseDown(with: event)
        onEditingChanged?(false)
    }
}
