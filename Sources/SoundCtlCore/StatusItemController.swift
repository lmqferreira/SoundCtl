import AppKit
import ServiceManagement
import ApplicationServices

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
    private let hwVolume: HardwareVolumeController

    init() {
        coordinator = VolumeCoordinator(audio: audio, ddc: ddc)
        model = PopoverModel(audio: audio, coordinator: coordinator)
        panel = PanelController(model: model)
        hwVolume = HardwareVolumeController(audio: audio, coordinator: coordinator, ddc: ddc)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // isVisible is auto-persisted by AppKit; force it on at launch so a prior
        // "Don't Show in Menu Bar" (session-only by design) is restored on relaunch.
        statusItem.isVisible = true
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
        hwVolume.onVolumeChanged = { [weak self] value, muted in
            self?.updateIcon(value: value, muted: muted)
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

        // Scroll the wheel over the menu-bar icon to change volume (like the
        // native Sound icon). A local monitor needs no Accessibility permission.
        installMenuBarScrollMonitor()

        // Take over the hardware volume keys for DDC displays. If Accessibility
        // isn't granted yet, keep retrying so it starts working as soon as the
        // user enables it (no relaunch needed).
        Log.write("launch: starting volume-key handling")
        beginVolumeKeys()
    }

    private var menuScrollMonitor: Any?

    private func installMenuBarScrollMonitor() {
        menuScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let button = self.statusItem.button,
                  let window = button.window else { return event }
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            guard frame.contains(NSEvent.mouseLocation) else { return event }
            let raw = Double(event.scrollingDeltaY)
            let lines = event.hasPreciseScrollingDeltas ? raw / 40.0 : raw
            self.hwVolume.adjustCurrentDevice(by: Float(lines * (1.0 / 16.0)))
            return nil
        }
    }

    private var permissionTimer: Timer?

    private func beginVolumeKeys() {
        if hwVolume.start() { return }
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.hwVolume.isActive || self.hwVolume.start() {
                timer.invalidate()
            }
        }
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
        let headphones = audio.defaultDevice?.isHeadphones ?? false
        applyIcon(value: value, muted: muted, headphones: headphones)
    }

    private func applyIcon(value: Float, muted: Bool, headphones: Bool) {
        guard let button = statusItem.button else { return }
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

    // MARK: - Right-click menu (app controls)

    private func showContextMenu(from button: NSStatusBarButton) {
        if panel.isShown { panel.close() }
        // The user may have just granted Accessibility — retry installing the tap.
        if !hwVolume.isActive { hwVolume.start() }
        let menu = NSMenu()

        if !hwVolume.isActive {
            let enable = NSMenuItem(title: "Grant Accessibility Access for Volume Keys…",
                                    action: #selector(enableVolumeKeys), keyEquivalent: "")
            enable.target = self
            menu.addItem(enable)
            menu.addItem(.separator())
        }

        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        login.target = self
        login.state = isOpenAtLoginEnabled ? .on : .off

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self

        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(quit)

        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 5),
                   in: button)
    }

    /// Prompts for Accessibility (required by the volume-key event tap) and opens
    /// the relevant Settings pane. The keys start working once granted.
    @objc private func enableVolumeKeys() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // Try again shortly in case the grant takes effect without a relaunch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.hwVolume.start()
        }
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
