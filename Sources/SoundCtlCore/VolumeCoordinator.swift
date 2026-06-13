import AppKit

/// Bridges the UI to either the CoreAudio volume path (software devices) or the
/// DDC path (displays). This is the single seam where the "magic" lives: when a
/// device maps to a DDC display, the slider stays enabled and drives the monitor.
final class VolumeCoordinator {

    let audio: AudioController
    let ddc: DDCController

    /// Called after a DDC volume write so other components (e.g. the hardware
    /// volume keys) can keep their cached level in sync with the popover.
    var onVolumeWritten: ((Float, AudioDevice) -> Void)?

    init(audio: AudioController, ddc: DDCController) {
        self.audio = audio
        self.ddc = ddc
    }

    struct State {
        var value: Float          // 0...1 knob position
        var enabled: Bool         // slider interactive?
        var mutedLook: Bool       // render grey fill
        var iconLevel: IconLevel  // for status-item + flanking glyphs
    }

    enum IconLevel {
        case muted, low, mid, high

        static func from(value: Float, muted: Bool) -> IconLevel {
            if muted || value <= 0.001 { return .muted }
            if value < 0.34 { return .low }
            if value < 0.67 { return .mid }
            return .high
        }
    }

    func state(for device: AudioDevice) -> State {
        if let display = ddc.display(matching: device) {
            let v = display.readVolume() ?? 0
            let muted = Self.isMutedLook(value: v, hardwareMuted: false)
            return State(value: v, enabled: true, mutedLook: muted,
                         iconLevel: .from(value: v, muted: muted))
        }
        let enabled = audio.hasSettableVolume(device.id)
        let v = audio.volume(device.id) ?? 0
        let hardwareMuted = audio.hasMute(device.id) && audio.isMuted(device.id)
        let muted = Self.isMutedLook(value: v, hardwareMuted: hardwareMuted)
        return State(value: v, enabled: enabled, mutedLook: muted,
                     iconLevel: .from(value: v, muted: muted))
    }

    /// A device reads as "muted" (slash icon) when the hardware mute flag is set
    /// *or* the volume is effectively zero — matching native, and ensuring the
    /// slash persists after the slider is released at 0.
    static func isMutedLook(value: Float, hardwareMuted: Bool) -> Bool {
        hardwareMuted || value <= 0.001
    }

    func setVolume(_ value: Float, for device: AudioDevice) {
        if let display = ddc.display(matching: device) {
            display.writeVolume(value)
            onVolumeWritten?(value, device)
            return
        }
        if value > 0 && audio.hasMute(device.id) && audio.isMuted(device.id) {
            audio.setMuted(false, for: device.id)
        }
        audio.setVolume(value, for: device.id)
    }
}
