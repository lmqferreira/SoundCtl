import AppKit
import CoreAudio

/// Builds and binds the Sound popover contents to match the native legacy
/// menu-bar control: title, volume slider with flanking glyphs, the Output
/// device list, and a "Sound Settings…" row.
final class SoundPopoverViewController: NSViewController {

    private let audio: AudioController
    private let coordinator: VolumeCoordinator

    private let contentWidth: CGFloat = 307

    let titleLabel = NSTextField(labelWithString: "Sound")
    let outputHeader = NSTextField(labelWithString: "Output")
    let slider = VolumeSlider()
    private let leftGlyph = ClickableGlyphView()
    let rightGlyph = ClickableGlyphView()
    let devicesStack = NSStackView()
    private(set) var settingsRow: TextHoverRow!

    /// Reports (volume 0...1, muted) so the menu-bar icon can mirror the level.
    var onVolumeStateChange: ((Float, Bool) -> Void)?

    /// Invoked when the panel should dismiss (e.g. after opening Sound Settings).
    var onRequestClose: (() -> Void)?

    /// Indirection so tests can capture the URL instead of launching System Settings.
    var openURLHandler: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var isUserAdjusting = false
    private var displayedDeviceIDs: [AudioDeviceID] = []

    init(audio: AudioController, coordinator: VolumeCoordinator) {
        self.audio = audio
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        // Round the corners with the layer's cornerRadius but WITHOUT
        // masksToBounds / maskImage — both of those rasterize the material and
        // make it look opaque. cornerRadius alone keeps the frosted vibrancy.
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 13
        effect.translatesAutoresizingMaskIntoConstraints = false
        view = effect
        buildLayout(in: effect)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        audio.refreshDevices()
        rebind()
    }

    // MARK: - Layout

    private func buildLayout(in root: NSView) {
        titleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        outputHeader.font = .systemFont(ofSize: 11, weight: .bold)
        outputHeader.textColor = .labelColor
        outputHeader.translatesAutoresizingMaskIntoConstraints = false

        configureGlyph(leftGlyph, symbol: "speaker.fill")
        configureGlyph(rightGlyph, symbol: "speaker.wave.3.fill")
        // Label colour so the variable-symbol arcs show dark (active) vs grey
        // (above current level), matching native.
        rightGlyph.contentTintColor = .labelColor

        let sliderRow = makeSliderRow()
        let separator1 = makeSeparator()
        let separator2 = makeSeparator()

        devicesStack.orientation = .vertical
        devicesStack.spacing = 0
        devicesStack.alignment = .leading
        devicesStack.translatesAutoresizingMaskIntoConstraints = false

        let settingsRow = TextHoverRow(title: "Sound Settings…") { [weak self] in
            self?.openSoundSettings()
        }
        self.settingsRow = settingsRow

        for v in [titleLabel, sliderRow, separator1, outputHeader,
                  devicesStack, separator2, settingsRow] {
            root.addSubview(v)
        }

        root.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            sliderRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            sliderRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sliderRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            separator1.topAnchor.constraint(equalTo: sliderRow.bottomAnchor, constant: 6),
            separator1.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 13),
            separator1.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -13),

            outputHeader.topAnchor.constraint(equalTo: separator1.bottomAnchor, constant: 6),
            outputHeader.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),

            devicesStack.topAnchor.constraint(equalTo: outputHeader.bottomAnchor, constant: 2),
            devicesStack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            devicesStack.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            separator2.topAnchor.constraint(equalTo: devicesStack.bottomAnchor, constant: 4),
            separator2.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 13),
            separator2.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -13),

            settingsRow.topAnchor.constraint(equalTo: separator2.bottomAnchor, constant: 2),
            settingsRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            settingsRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            settingsRow.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6)
        ])
    }

    private func makeSliderRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.onChange = { [weak self] value in self?.handleSliderChange(value) }
        slider.onEditingChanged = { [weak self] editing in
            self?.isUserAdjusting = editing
            if !editing { self?.refreshVolumeOnly() }
        }

        row.addSubview(leftGlyph)
        row.addSubview(slider)
        row.addSubview(rightGlyph)

        // Click the speaker glyphs to step the volume down / up (like native).
        leftGlyph.onClick = { [weak self] in self?.handleSpeakerGlyphClick(isLeftSpeaker: true) }
        rightGlyph.onClick = { [weak self] in self?.handleSpeakerGlyphClick(isLeftSpeaker: false) }

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 24),
            leftGlyph.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            leftGlyph.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            leftGlyph.widthAnchor.constraint(equalToConstant: 20),
            leftGlyph.heightAnchor.constraint(equalToConstant: 18),

            slider.leadingAnchor.constraint(equalTo: leftGlyph.trailingAnchor, constant: 6),
            slider.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            slider.heightAnchor.constraint(equalToConstant: 22),

            rightGlyph.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 6),
            rightGlyph.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            rightGlyph.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            rightGlyph.widthAnchor.constraint(equalToConstant: 24),
            rightGlyph.heightAnchor.constraint(equalToConstant: 18)
        ])
        return row
    }

    private func configureGlyph(_ view: NSImageView, symbol: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        view.contentTintColor = .secondaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        // Render at the symbol's natural size (no scaling) so the speaker body
        // is identical on both sides — only the wave arcs differ.
        view.imageScaling = .scaleNone
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    // MARK: - Binding

    func rebind() {
        rebuildDeviceRows()
        refreshVolumeOnly()
    }

    /// Updates only the slider + glyphs for the current default device, without
    /// touching the device-row list (so the popover never resizes/moves mid-drag).
    func refreshVolumeOnly() {
        guard !isUserAdjusting else { return }
        guard let device = audio.defaultDevice else {
            slider.isEnabledControl = false
            return
        }
        let state = coordinator.state(for: device)
        slider.value = state.value
        slider.isEnabledControl = state.enabled
        slider.isMutedLook = state.mutedLook
        updateFlankingGlyphs(value: state.value, muted: state.mutedLook)
        onVolumeStateChange?(state.value, state.mutedLook)
    }

    private func rebuildDeviceRows() {
        let defaultID = audio.defaultOutputDeviceID
        let currentIDs = audio.devices.map { $0.id }

        // Only tear down and rebuild when the set of devices actually changed.
        // Otherwise just update which row is selected.
        if currentIDs == displayedDeviceIDs {
            for case let row as OutputDeviceRow in devicesStack.arrangedSubviews {
                row.setSelected(row.deviceID == defaultID)
            }
            return
        }

        for v in devicesStack.arrangedSubviews {
            devicesStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for device in audio.devices {
            let row = OutputDeviceRow(deviceID: device.id,
                                      symbol: device.iconSymbol,
                                      name: device.name,
                                      selected: device.id == defaultID)
            row.onClick = { [weak self] in self?.selectDevice(device) }
            devicesStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: devicesStack.widthAnchor).isActive = true
        }
        displayedDeviceIDs = currentIDs
    }

    /// Native renders the high-side glyph as a *variable* SF Symbol: the wave
    /// arcs fill in proportion to the volume and grey out below the current
    /// level. The low-side glyph is a static plain speaker.
    private func updateFlankingGlyphs(value: Float, muted: Bool) {
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)

        leftGlyph.image = NSImage(systemSymbolName: IconSymbols.leftFlank(muted: muted),
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(config)

        let variable = muted ? 0.0 : Double(max(0, min(1, value)))
        rightGlyph.image = NSImage(systemSymbolName: IconSymbols.rightFlank,
                                   variableValue: variable,
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    // MARK: - Actions

    private func handleSliderChange(_ value: Float) {
        guard let device = audio.defaultDevice else { return }
        coordinator.setVolume(value, for: device)
        let muted = value <= 0.001
        slider.isMutedLook = muted
        updateFlankingGlyphs(value: value, muted: muted)
        onVolumeStateChange?(value, muted)
    }

    /// Clicking the low/high speaker nudges the volume down/up by one step —
    /// native behaviour (1/10 per click).
    func handleSpeakerGlyphClick(isLeftSpeaker: Bool) {
        guard let device = audio.defaultDevice, slider.isEnabledControl else { return }
        let target = Self.steppedVolume(current: slider.value, isLeftSpeaker: isLeftSpeaker)
        coordinator.setVolume(target, for: device)
        let muted = VolumeCoordinator.isMutedLook(value: target, hardwareMuted: false)
        slider.value = target
        slider.isMutedLook = muted
        updateFlankingGlyphs(value: target, muted: muted)
        onVolumeStateChange?(target, muted)
    }

    /// One volume step up or down, snapped to a 1/10 grid and clamped to 0...1.
    static func steppedVolume(current: Float, isLeftSpeaker: Bool, notches: Float = 10) -> Float {
        let steps = (current * notches).rounded() + (isLeftSpeaker ? -1 : 1)
        return max(0, min(1, steps / notches))
    }

    private func selectDevice(_ device: AudioDevice) {
        audio.setDefaultDevice(device)
        rebind()
        onRequestClose?()
    }

    private func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            openURLHandler(url)
        }
        onRequestClose?()
    }
}
