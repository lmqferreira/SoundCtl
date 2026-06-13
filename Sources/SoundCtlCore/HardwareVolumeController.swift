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
        let device = audio.defaultDevice
        let display = device.flatMap { ddc.display(matching: $0) }
        let bd = betterDisplay.isRunning
        let shouldHandle = display != nil && !bd
        if isDown {
            Log.write("key=\(key) down repeat=\(isRepeat) device=\(device?.name ?? "nil") hasDDC=\(display != nil) betterDisplay=\(bd) -> handle=\(shouldHandle)")
        }
        guard let device, let display, !bd else { return false }
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
            let read = display.readVolume() ?? cachedVolume ?? 0
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

    /// The next grid value above/below the current 0...1 level.
    static func nextVolume(current: Float, up: Bool) -> Float {
        let pct = Int((max(0, min(1, current)) * 100).rounded())
        let target = up ? (stepGrid.first { $0 > pct } ?? 100)
                        : (stepGrid.last { $0 < pct } ?? 0)
        return Float(target) / 100
    }
}
