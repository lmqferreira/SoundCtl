import AppKit
import CoreAudio

/// Bridges the UI to either the CoreAudio volume path (software devices) or the
/// DDC path (displays). This is the single seam where the "magic" lives: when a
/// device maps to a DDC display, the slider stays enabled and drives the monitor.
///
/// DDC I2C reads are slow (tens-to-hundreds of ms) and MUST NOT run on the main
/// thread — they would beachball the UI and can self-disable the volume-key event
/// tap. So the coordinator keeps a main-thread-only cache of each display's level,
/// updated synchronously on our own writes and refreshed asynchronously off the
/// main thread; all synchronous callers (`state(for:)`, the icon, the keys, the
/// HUD) read the cache and never block.
final class VolumeCoordinator {

    let audio: AudioController
    let ddc: DDCController

    /// Called after a DDC volume write so other components (e.g. the hardware
    /// volume keys) can keep their cached level in sync with the popover.
    var onVolumeWritten: ((Float, AudioDevice) -> Void)?

    /// Called on the main thread when an async DDC read updates the cached level,
    /// so the UI can re-render with the freshly read value.
    var onDDCVolumeRefreshed: ((AudioDevice) -> Void)?

    private let readQueue = DispatchQueue(label: "com.lmqferreira.soundctl.ddc.read")
    private var ddcCache: [AudioDeviceID: Float] = [:]   // main-thread only

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

    /// Synchronous, non-blocking snapshot. For DDC displays it returns the cached
    /// level (seed it with `refreshDDCVolume(for:)`); for software devices it
    /// reads CoreAudio, which is fast.
    func state(for device: AudioDevice) -> State {
        if ddc.display(matching: device) != nil {
            let v = ddcCache[device.id] ?? 0
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

    /// Last cached DDC level (nil until first read/write), for the volume keys.
    func cachedDDCVolume(for device: AudioDevice) -> Float? {
        ddcCache[device.id]
    }

    /// Reads the display's level off the main thread and updates the cache,
    /// notifying `onDDCVolumeRefreshed` on the main thread when it changes.
    func refreshDDCVolume(for device: AudioDevice) {
        guard let display = ddc.display(matching: device) else { return }
        let id = device.id
        readQueue.async { [weak self] in
            let value = display.readVolume()
            DispatchQueue.main.async {
                guard let self, let value else { return }
                if self.ddcCache[id] != value {
                    self.ddcCache[id] = value
                    self.onDDCVolumeRefreshed?(device)
                }
            }
        }
    }

    /// A device reads as "muted" (slash icon) when the hardware mute flag is set
    /// *or* the volume is effectively zero — matching native, and ensuring the
    /// slash persists after the slider is released at 0.
    static func isMutedLook(value: Float, hardwareMuted: Bool) -> Bool {
        hardwareMuted || value <= 0.001
    }

    func setVolume(_ value: Float, for device: AudioDevice) {
        let clamped = max(0, min(1, value))
        if let display = ddc.display(matching: device) {
            display.writeVolume(clamped)
            ddcCache[device.id] = clamped       // our own write is the source of truth
            onVolumeWritten?(clamped, device)
            return
        }
        if clamped > 0 && audio.hasMute(device.id) && audio.isMuted(device.id) {
            audio.setMuted(false, for: device.id)
        }
        audio.setVolume(clamped, for: device.id)
    }
}
