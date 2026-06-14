import AppKit
import CoreAudio
import ApplicationServices

/// Owns the hardware volume-key handling: when the current output is a
/// DDC-controlled display (which macOS can't adjust natively) and BetterDisplay
/// isn't running, it intercepts the volume keys, drives the monitor over DDC,
/// and shows the on-screen HUD. For every other case it lets the keys pass
/// through so the system handles normal devices itself.
final class HardwareVolumeController {

    /// Volume-key value grid (in 0–100 monitor units): steps of 2 up to 10,
    /// then 5 up to 50, then 10 up to 100. Pressing up/down moves to the next
    /// grid value (snapping cleanly even from an off-grid level).
    static let stepGrid: [Int] = [0, 2, 4, 6, 8, 10, 15, 20, 25, 30, 35, 40, 45, 50, 60, 70, 80, 90, 100]

    private let audio: AudioController
    private let coordinator: VolumeCoordinator
    private let ddc: DDCController
    private let monitor = VolumeKeyMonitor()
    private let hud = VolumeHUD()
    var betterDisplay = BetterDisplayDetector()

    /// Reports (volume 0...1, muted) after a key-driven change so the menu-bar
    /// icon can mirror the level with the same variable-symbol effect as the HUD.
    var onVolumeChanged: ((Float, Bool) -> Void)?

    private var cachedDeviceID: AudioDeviceID = 0
    private var cachedVolume: Float?
    private var preMuteVolume: Float?
    private var muted = false

    init(audio: AudioController, coordinator: VolumeCoordinator, ddc: DDCController) {
        self.audio = audio
        self.coordinator = coordinator
        self.ddc = ddc

        monitor.handler = { [weak self] key, isDown, isRepeat in
            self?.handle(key: key, isDown: isDown, isRepeat: isRepeat) ?? false
        }
        // Keep the cached level in sync with volume changes made in the popover.
        coordinator.onVolumeWritten = { [weak self] value, device in
            self?.sync(value: value, device: device)
        }
    }

    /// Installs the key tap. Returns false when Accessibility isn't granted.
    @discardableResult
    func start() -> Bool {
        let trusted = AXIsProcessTrusted()
        let ok = monitor.start()
        Log.write("hwVolume.start trusted=\(trusted) tapInstalled=\(ok) active=\(monitor.isActive)")
        return ok
    }
    var isActive: Bool { monitor.isActive }
    var isTrusted: Bool { AXIsProcessTrusted() }
    func stop() { monitor.stop() }

    // MARK: - Routing

    /// Returns true to consume the key (we handled it), false to pass it through.
    private func handle(key: VolumeKeyMonitor.Key, isDown: Bool, isRepeat: Bool) -> Bool {
        guard let device = audio.defaultDevice,
              let display = ddc.display(matching: device),
              !betterDisplay.isRunning else {
            return false
        }
        guard isDown else { return true }   // consume the matching key-up too

        ensureCache(device: device, display: display)
        switch key {
        case .up:   applyVolume(Self.nextVolume(current: cachedVolume ?? 0, up: true), device: device)
        case .down: applyVolume(Self.nextVolume(current: cachedVolume ?? 0, up: false), device: device)
        case .mute: if !isRepeat { toggleMute(device: device) }
        }
        return true
    }

    private func ensureCache(device: AudioDevice, display: DDCDisplay) {
        if cachedDeviceID != device.id || cachedVolume == nil {
            cachedDeviceID = device.id
            // Non-blocking: use the coordinator's cached DDC level (seeded async
            // at launch / on device change) — never a synchronous I2C read here,
            // since this runs in the event-tap callback on the main thread.
            let read = coordinator.cachedDDCVolume(for: device) ?? cachedVolume ?? 0
            cachedVolume = read
            muted = read <= 0.001
            preMuteVolume = nil
        }
    }

    private func applyVolume(_ new: Float, device: AudioDevice) {
        cachedVolume = new
        muted = new <= 0.001
        preMuteVolume = nil
        coordinator.setVolume(new, for: device)
        hud.show(level: new, muted: muted)
        onVolumeChanged?(new, muted)
    }

    private func toggleMute(device: AudioDevice) {
        if muted {
            let restore = preMuteVolume ?? 0
            let value = restore <= 0.001 ? 0.10 : restore
            cachedVolume = value
            muted = false
            preMuteVolume = nil
            coordinator.setVolume(value, for: device)
            hud.show(level: value, muted: false)
            onVolumeChanged?(value, false)
        } else {
            preMuteVolume = cachedVolume
            cachedVolume = 0
            muted = true
            coordinator.setVolume(0, for: device)
            hud.show(level: 0, muted: true)
            onVolumeChanged?(0, true)
        }
    }

    private func sync(value: Float, device: AudioDevice) {
        cachedDeviceID = device.id
        cachedVolume = value
        muted = value <= 0.001
    }

    /// Adjust the current default output by a delta (for scrolling over the
    /// menu-bar icon). Works for DDC displays and software devices alike, shows
    /// the HUD, and reports the new level for the menu-bar icon.
    func adjustCurrentDevice(by delta: Float) {
        guard delta != 0, let device = audio.defaultDevice else { return }
        let current = currentVolume(for: device)
        let new = max(0, min(1, current + delta))
        cachedDeviceID = device.id
        cachedVolume = new
        muted = new <= 0.001
        preMuteVolume = nil
        coordinator.setVolume(new, for: device)
        hud.show(level: new, muted: muted)
        onVolumeChanged?(new, muted)
    }

    private func currentVolume(for device: AudioDevice) -> Float {
        if ddc.display(matching: device) != nil {
            // Non-blocking: cached DDC level (our own writes keep it exact; the
            // coordinator seeds it asynchronously). Never a synchronous I2C read.
            if cachedDeviceID == device.id, let cached = cachedVolume { return cached }
            return coordinator.cachedDDCVolume(for: device) ?? 0
        }
        // Software device: CoreAudio reads are cheap, so always read fresh to
        // avoid drift from changes made elsewhere.
        return audio.volume(device.id) ?? 0
    }

    // MARK: - Pure logic (testable)

    /// The next grid value above/below the current 0...1 level.
    static func nextVolume(current: Float, up: Bool) -> Float {
        let pct = Int((max(0, min(1, current)) * 100).rounded())
        let target = up ? (stepGrid.first { $0 > pct } ?? 100)
                        : (stepGrid.last { $0 < pct } ?? 0)
        return Float(target) / 100
    }
}
