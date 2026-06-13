import AppKit
import ServiceManagement

/// How the menu-bar item is shown, mirroring the native right-click options.
enum MenuBarVisibility: String {
    case alwaysShow
    case showWhenActive
}

/// Owns the menu-bar status item and a key panel hosting the Sound content.
/// A key window is required so the native NSSlider renders active (blue); the
/// panel also gives us the exact right/left placement and the Liquid Glass
/// material via the content view.
final class StatusItemController {
    private let statusItem: NSStatusItem

    private let audio = AudioController()
    private let ddc = DDCController()
    private let coordinator: VolumeCoordinator
    private let model: PopoverModel
    private let panel: PanelController

    init() {
        coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        model = PopoverModel(audio: audio, coordinator: coordinator)
        panel = PanelController(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.onVolumeStateChange = { [weak self] value, muted in
            self?.updateIcon(value: value, muted: muted)
        }
        model.onRequestClose = { [weak self] in
            self?.panel.close()
        }
        panel.onVisibilityChanged = { [weak self] shown in
            self?.setHighlighted(shown)
        }

        audio.onDeviceListChange = { [weak self] in
            guard let self else { return }
            if self.panel.isShown { self.model.reload() } else { self.refreshIcon() }
        }
        audio.onVolumeChange = { [weak self] in
            guard let self else { return }
            if self.panel.isShown { self.model.refreshVolumeOnly() } else { self.refreshIcon() }
        }

        refreshIcon()
    }

    // MARK: - Highlight

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

    /// Headphones when the output is headphones, `speaker.slash.fill` at
    /// zero/mute, otherwise the variable 3-arc speaker tracking the level.
    private func updateIcon(value: Float, muted: Bool) {
        guard let button = statusItem.button else { return }
        let headphones = audio.defaultDevice?.isHeadphones ?? false
        // The headphones glyph is optically larger than the speaker at the same
        // point size, so render it a touch smaller to match the native menu bar.
        let pointSize = headphones ? Self.headphonesPointSize : Self.iconPointSize
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        let symbol = IconSymbols.statusBar(muted: muted, headphones: headphones)
        let image: NSImage?
        if headphones || muted {
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
        if panel.isShown { button.highlight(true) }
    }

    private static let iconPointSize: CGFloat = 15
    private static let headphonesPointSize: CGFloat = 14

    // MARK: - Clicks

    @objc private func handleClick() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isSecondary {
            showContextMenu(from: button)
        } else {
            panel.toggle(relativeTo: button)
        }
    }

    // MARK: - Right-click menu (menu-bar visibility + login + quit)

    private func showContextMenu(from button: NSStatusBarButton) {
        if panel.isShown { panel.close() }
        let menu = NSMenu()

        let always = NSMenuItem(title: "Always Show In Menu Bar",
                                action: #selector(setAlwaysShow), keyEquivalent: "")
        always.target = self
        always.state = visibility == .alwaysShow ? .on : .off

        let active = NSMenuItem(title: "Show When Active",
                                action: #selector(setShowWhenActive), keyEquivalent: "")
        active.target = self
        active.state = visibility == .showWhenActive ? .on : .off

        let hide = NSMenuItem(title: "Don't Show in Menu Bar",
                              action: #selector(setDontShow), keyEquivalent: "")
        hide.target = self

        let login = NSMenuItem(title: "Open at Login",
                               action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = isOpenAtLoginEnabled ? .on : .off

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        for item in [always, active, hide] { menu.addItem(item) }
        menu.addItem(.separator())
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    private var visibility: MenuBarVisibility {
        get {
            MenuBarVisibility(rawValue: UserDefaults.standard.string(forKey: "menuBarVisibility") ?? "")
                ?? .alwaysShow
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "menuBarVisibility") }
    }

    @objc private func setAlwaysShow() {
        visibility = .alwaysShow
        statusItem.isVisible = true
    }

    @objc private func setShowWhenActive() {
        visibility = .showWhenActive
        statusItem.isVisible = true
    }

    /// Hides the icon for this session; it returns on next launch (we don't
    /// persist the hidden state, so the user can always relaunch to restore it).
    @objc private func setDontShow() {
        statusItem.isVisible = false
    }

    // MARK: - Open at Login (ServiceManagement)

    private var isOpenAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("SoundCtl: Open at Login toggle failed: \(error)")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
