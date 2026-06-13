import AppKit

/// Owns the menu-bar status item and a borderless panel hosting the Sound
/// content. The panel gives full control over the (right-aligned) positioning
/// and the frosted material; we keep the status item highlighted while it's open.
final class StatusItemController {
    private let statusItem: NSStatusItem

    private let audio = AudioController()
    private let ddc = DDCController()
    private let coordinator: VolumeCoordinator
    private let popoverVC: SoundPopoverViewController
    private let panel: PanelController

    init() {
        coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        popoverVC = SoundPopoverViewController(audio: audio, coordinator: coordinator)
        panel = PanelController(viewController: popoverVC)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel)
        }

        popoverVC.onVolumeStateChange = { [weak self] value, muted in
            self?.updateIcon(value: value, muted: muted)
        }
        popoverVC.onRequestClose = { [weak self] in
            self?.panel.close()
        }
        panel.onVisibilityChanged = { [weak self] shown in
            self?.setHighlighted(shown)
        }

        audio.onDeviceListChange = { [weak self] in
            guard let self else { return }
            if self.panel.isShown { self.popoverVC.rebind() } else { self.refreshIcon() }
        }
        audio.onVolumeChange = { [weak self] in
            guard let self else { return }
            if self.panel.isShown { self.popoverVC.refreshVolumeOnly() } else { self.refreshIcon() }
        }

        refreshIcon()
    }

    // MARK: - Highlight

    /// Setting the highlight synchronously during the button's click gets reset
    /// when the click finishes, so defer it past the current event. Cleared
    /// immediately on close.
    private func setHighlighted(_ highlighted: Bool) {
        guard let button = statusItem.button else { return }
        if highlighted {
            DispatchQueue.main.async { button.highlight(true) }
        } else {
            button.highlight(false)
        }
    }

    // MARK: - Icon

    private func refreshIcon() {
        guard let device = audio.defaultDevice else {
            updateIcon(value: 0, muted: true)
            return
        }
        let state = coordinator.state(for: device)
        updateIcon(value: state.value, muted: state.mutedLook)
    }

    /// The menu-bar glyph is always `speaker.wave.3.fill` rendered as a variable
    /// symbol (constant width), or `speaker.slash.fill` at zero/mute.
    private func updateIcon(value: Float, muted: Bool) {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .regular)
        let symbol = IconSymbols.statusBar(muted: muted)
        let image: NSImage?
        if muted {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Sound")?
                .withSymbolConfiguration(config)
        } else {
            image = NSImage(systemSymbolName: symbol,
                            variableValue: Double(max(0, min(1, value))),
                            accessibilityDescription: "Sound")?
                .withSymbolConfiguration(config)
        }
        image?.isTemplate = true
        button.image = image
        // Re-assert the highlight: changing the image while open would otherwise
        // drop the selected appearance mid-drag.
        if panel.isShown { button.highlight(true) }
    }

    /// Tuned to match the native menu-bar speaker glyph size.
    private static let iconPointSize: CGFloat = 15

    // MARK: - Panel

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panel.toggle(relativeTo: button)
    }
}
