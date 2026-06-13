import AppKit

/// Owns the menu-bar status item and hosts the Sound content inside a native
/// NSMenu (statusItem.menu auto-display). This gives the genuine translucent
/// menu material, the persistent button highlight, native positioning and
/// dismissal — none of which a hand-rolled panel reproduces. (Rectangle-style.)
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let contentItem = NSMenuItem()

    private let audio = AudioController()
    private let ddc = DDCController()
    private let coordinator: VolumeCoordinator
    private let popoverVC: SoundPopoverViewController

    override init() {
        coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        popoverVC = SoundPopoverViewController(audio: audio, coordinator: coordinator)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        _ = popoverVC.view
        contentItem.view = popoverVC.view
        menu.addItem(contentItem)
        menu.delegate = self
        statusItem.menu = menu

        popoverVC.onVolumeStateChange = { [weak self] value, muted in
            self?.updateIcon(value: value, muted: muted)
        }
        popoverVC.onRequestClose = { [weak self] in
            self?.menu.cancelTracking()
        }

        audio.onDeviceListChange = { [weak self] in self?.refreshIcon() }
        audio.onVolumeChange = { [weak self] in self?.refreshIcon() }

        refreshIcon()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        audio.refreshDevices()
        popoverVC.rebind()
        let size = popoverVC.view.fittingSize
        popoverVC.view.setFrameSize(size)
        popoverVC.view.layoutSubtreeIfNeeded()
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
    }

    /// Tuned to match the native menu-bar speaker glyph size.
    private static let iconPointSize: CGFloat = 15
}
