import AppKit
import CoreAudio

/// Observable state backing the SwiftUI Sound popover. Bridges the SwiftUI view
/// to the CoreAudio + DDC controllers, and owns the pure volume-stepping logic
/// (kept here so it stays unit-testable without any view).
final class PopoverModel: ObservableObject {

    struct DeviceItem: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let symbol: String
    }

    @Published var volume: Double = 0          // 0...1 knob position
    @Published var enabled: Bool = true        // slider interactive?
    @Published var mutedLook: Bool = false      // slash glyph at zero/mute
    @Published var devices: [DeviceItem] = []
    @Published var selectedID: AudioDeviceID = 0

    /// Reports (volume 0...1, muted) so the menu-bar icon can mirror the level.
    var onVolumeStateChange: ((Float, Bool) -> Void)?
    /// Invoked when the popover should dismiss (device switch / settings).
    var onRequestClose: (() -> Void)?
    /// Indirection so tests can capture the URL instead of launching Settings.
    var openURLHandler: (URL) -> Void = { NSWorkspace.shared.open($0) }

    static let soundSettingsURL = "x-apple.systempreferences:com.apple.Sound-Settings.extension"

    private let audio: AudioController
    private let coordinator: VolumeCoordinator
    private var isUserAdjusting = false

    init(audio: AudioController, coordinator: VolumeCoordinator) {
        self.audio = audio
        self.coordinator = coordinator
    }

    // MARK: - Binding

    /// Rebuilds the device list and refreshes the slider for the default device.
    func reload() {
        audio.refreshDevices()
        devices = audio.devices.map { DeviceItem(id: $0.id, name: $0.name, symbol: $0.iconSymbol) }
        selectedID = audio.defaultOutputDeviceID
        // Kick an async DDC read so the slider settles on the real level shortly
        // after open (the cached value renders immediately, no blocking).
        if let device = audio.defaultDevice {
            coordinator.refreshDDCVolume(for: device)
        }
        refreshVolumeOnly()
    }

    /// Updates only the slider + glyph state for the current default device
    /// (never mid-drag, so the popover never fights the user's gesture).
    func refreshVolumeOnly() {
        guard !isUserAdjusting else { return }
        guard let device = audio.defaultDevice else {
            enabled = false
            return
        }
        let state = coordinator.state(for: device)
        volume = Double(state.value)
        enabled = state.enabled
        mutedLook = state.mutedLook
        onVolumeStateChange?(state.value, state.mutedLook)
    }

    // MARK: - Slider

    func beginAdjust() { isUserAdjusting = true }
    func endAdjust() { isUserAdjusting = false; refreshVolumeOnly() }

    func setVolume(_ value: Double) {
        guard let device = audio.defaultDevice else { return }
        let v = Float(max(0, min(1, value)))
        coordinator.setVolume(v, for: device)
        volume = Double(v)
        mutedLook = VolumeCoordinator.isMutedLook(value: v, hardwareMuted: false)
        onVolumeStateChange?(v, mutedLook)
    }

    /// Clicking a flanking speaker nudges the volume by one 1/10 step (native).
    func step(isLeftSpeaker: Bool) {
        guard enabled, audio.defaultDevice != nil else { return }
        let target = Self.steppedVolume(current: Float(volume), isLeftSpeaker: isLeftSpeaker)
        setVolume(Double(target))
    }

    // MARK: - Devices / settings

    /// Nudge the volume by a delta (used by scroll-wheel over the popover).
    func nudgeVolume(by delta: Double) {
        guard enabled, audio.defaultDevice != nil, delta != 0 else { return }
        setVolume(max(0, min(1, volume + delta)))
    }

    func select(_ id: AudioDeviceID) {
        guard let device = audio.devices.first(where: { $0.id == id }) else { return }
        audio.setDefaultDevice(device)
        reload()
        onRequestClose?()
    }

    func openSettings() {
        if let url = URL(string: Self.soundSettingsURL) { openURLHandler(url) }
        onRequestClose?()
    }

    // MARK: - Glyphs

    var rightGlyphSymbol: String { IconSymbols.rightFlank }

    // MARK: - Pure logic (testable)

    /// One volume step up or down, snapped to a 1/10 grid and clamped to 0...1.
    static func steppedVolume(current: Float, isLeftSpeaker: Bool, notches: Float = 10) -> Float {
        let steps = (current * notches).rounded() + (isLeftSpeaker ? -1 : 1)
        return max(0, min(1, steps / notches))
    }
}
