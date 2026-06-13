import AppKit
import CoreAudio

/// Owns the hardware volume-key handling: when the current output is a
/// DDC-controlled display (which macOS can't adjust natively) and BetterDisplay
/// isn't running, it intercepts the volume keys, drives the monitor over DDC,
/// and shows the on-screen HUD. For every other case it lets the keys pass
/// through so the system handles normal devices itself.
final class HardwareVolumeController {

    /// Volume change per key press (matches the native 1/16 audio step).
    static let step: Float = 1.0 / 16.0

    private let audio: AudioController
    private let coordinator: VolumeCoordinator
    private let ddc: DDCController
    private let monitor = VolumeKeyMonitor()
    private let hud = VolumeHUD()
    var betterDisplay = BetterDisplayDetector()

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
    func start() -> Bool { monitor.start() }
    var isActive: Bool { monitor.isActive }
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
        case .up:   applyDelta(Self.step, device: device)
        case .down: applyDelta(-Self.step, device: device)
        case .mute: if !isRepeat { toggleMute(device: device) }
        }
        return true
    }

    private func ensureCache(device: AudioDevice, display: DDCDisplay) {
        if cachedDeviceID != device.id || cachedVolume == nil {
            cachedDeviceID = device.id
            let read = display.readVolume() ?? cachedVolume ?? 0
            cachedVolume = read
            muted = read <= 0.001
            preMuteVolume = nil
        }
    }

    private func applyDelta(_ delta: Float, device: AudioDevice) {
        let new = Self.stepped(cachedVolume ?? 0, delta: delta)
        cachedVolume = new
        muted = new <= 0.001
        preMuteVolume = nil
        coordinator.setVolume(new, for: device)
        hud.show(level: new, muted: muted)
    }

    private func toggleMute(device: AudioDevice) {
        if muted {
            let restore = preMuteVolume ?? 0
            let value = restore <= 0.001 ? Self.step : restore
            cachedVolume = value
            muted = false
            preMuteVolume = nil
            coordinator.setVolume(value, for: device)
            hud.show(level: value, muted: false)
        } else {
            preMuteVolume = cachedVolume
            cachedVolume = 0
            muted = true
            coordinator.setVolume(0, for: device)
            hud.show(level: 0, muted: true)
        }
    }

    private func sync(value: Float, device: AudioDevice) {
        cachedDeviceID = device.id
        cachedVolume = value
        muted = value <= 0.001
    }

    // MARK: - Pure logic (testable)

    static func stepped(_ current: Float, delta: Float) -> Float {
        max(0, min(1, current + delta))
    }
}
