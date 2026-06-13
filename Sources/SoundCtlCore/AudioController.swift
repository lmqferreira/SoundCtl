import CoreAudio
import AudioToolbox
import Foundation

/// One selectable output device.
struct AudioDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.id == rhs.id
    }

    /// SF Symbol glyph chosen by transport type, to mirror the native list.
    var iconSymbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "macbook"
        case kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeHDMI:
            return "display"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        default:
            return "speaker.wave.2.fill"
        }
    }

    /// True for displays reached over the video link (DDC candidates).
    var isDisplayTransport: Bool {
        transport == kAudioDeviceTransportTypeDisplayPort ||
        transport == kAudioDeviceTransportTypeHDMI
    }

    /// True when this device is shown as headphones (Bluetooth), so the menu-bar
    /// icon can switch from a speaker to headphones like the native control.
    var isHeadphones: Bool { iconSymbol == "headphones" }
}

/// Thin wrapper over the CoreAudio HAL: enumerate output devices, read/write
/// the system default output, and read/write master volume + mute. Emits a
/// single `onChange` callback (on the main queue) whenever anything relevant
/// changes so the UI can re-render.
final class AudioController {

    var onDeviceListChange: (() -> Void)?
    var onVolumeChange: (() -> Void)?

    private(set) var devices: [AudioDevice] = []

    init() {
        refreshDevices()
        installSystemListeners()
        installDeviceListeners(for: defaultOutputDeviceID)
    }

    // MARK: - Device enumeration

    func refreshDevices() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            devices = []
            return
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids) == noErr else {
            devices = []
            return
        }

        devices = ids.compactMap { makeDevice($0) }
            .filter { hasOutputStreams($0.id) && canBeDefaultOutput($0.id) }
            .sorted { $0.id < $1.id }
    }

    private func makeDevice(_ id: AudioDeviceID) -> AudioDevice? {
        guard let name = stringProperty(id, kAudioObjectPropertyName,
                                        scope: kAudioObjectPropertyScopeGlobal) else {
            return nil
        }
        let uid = stringProperty(id, kAudioDevicePropertyDeviceUID,
                                 scope: kAudioObjectPropertyScopeGlobal) ?? ""
        let transport = uint32Property(id, kAudioDevicePropertyTransportType,
                                       scope: kAudioObjectPropertyScopeGlobal) ?? 0
        return AudioDevice(id: id, uid: uid, name: name, transport: transport)
    }

    private func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else {
            return false
        }
        return size > 0
    }

    /// The native Sound menu only lists devices that can actually be made the
    /// default output. Virtual routing devices (e.g. "Microsoft Teams Audio")
    /// report false here and are therefore hidden.
    private func canBeDefaultOutput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return true }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return true
        }
        return value != 0
    }

    // MARK: - Default output device

    var defaultOutputDeviceID: AudioDeviceID {
        get {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var id: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
            return id
        }
        set {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var id = newValue
            let size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
        }
    }

    var defaultDevice: AudioDevice? {
        let id = defaultOutputDeviceID
        return devices.first { $0.id == id }
    }

    func setDefaultDevice(_ device: AudioDevice) {
        removeDeviceListeners(for: defaultOutputDeviceID)
        defaultOutputDeviceID = device.id
        installDeviceListeners(for: device.id)
        dispatch(onDeviceListChange)
    }

    // MARK: - Volume (software / CoreAudio path)

    /// Whether this device exposes a settable scalar volume (built-in, USB, BT).
    /// Digital displays usually return false here — that's the greyed case.
    func hasSettableVolume(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &addr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        // Fall back to channel 1.
        addr.mElement = 1
        if AudioObjectHasProperty(id, &addr) {
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue {
                return true
            }
        }
        return false
    }

    /// Master volume 0...1 for `id`, or nil if not readable.
    func volume(_ id: AudioDeviceID) -> Float? {
        if let v = scalarVolume(id, element: kAudioObjectPropertyElementMain) {
            return v
        }
        // Average channels 1 and 2.
        let l = scalarVolume(id, element: 1)
        let r = scalarVolume(id, element: 2)
        switch (l, r) {
        case let (l?, r?): return (l + r) / 2
        case let (l?, nil): return l
        case let (nil, r?): return r
        default: return nil
        }
    }

    func setVolume(_ value: Float, for id: AudioDeviceID) {
        let v = max(0, min(1, value))
        if !setScalarVolume(v, id: id, element: kAudioObjectPropertyElementMain) {
            _ = setScalarVolume(v, id: id, element: 1)
            _ = setScalarVolume(v, id: id, element: 2)
        }
    }

    private func scalarVolume(_ id: AudioDeviceID, element: AudioObjectPropertyElement) -> Float? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    @discardableResult
    private func setScalarVolume(_ value: Float, id: AudioDeviceID,
                                 element: AudioObjectPropertyElement) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else {
            return false
        }
        var v = Float32(max(0, min(1, value)))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(id, &addr, 0, nil, size, &v) == noErr
    }

    // MARK: - Mute

    func hasMute(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectHasProperty(id, &addr)
    }

    func isMuted(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &muted)
        return muted != 0
    }

    func setMuted(_ muted: Bool, for id: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &addr, &settable) == noErr, settable.boolValue else {
            return
        }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(id, &addr, 0, nil, size, &value)
    }

    // MARK: - Listeners

    private let listenerQueue = DispatchQueue.main
    private var observedDeviceID: AudioDeviceID = 0

    private lazy var systemListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleSystemChange()
    }

    private lazy var deviceListenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.handleVolumeChange()
    }

    private func installSystemListeners() {
        for selector in [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, listenerQueue, systemListenerBlock)
        }
    }

    private func installDeviceListeners(for id: AudioDeviceID) {
        guard id != 0 else { return }
        observedDeviceID = id
        for (selector, scope, element) in deviceListenerAddresses() {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
            if AudioObjectHasProperty(id, &addr) {
                AudioObjectAddPropertyListenerBlock(id, &addr, listenerQueue, deviceListenerBlock)
            }
        }
    }

    private func removeDeviceListeners(for id: AudioDeviceID) {
        guard id != 0 else { return }
        for (selector, scope, element) in deviceListenerAddresses() {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
            if AudioObjectHasProperty(id, &addr) {
                AudioObjectRemovePropertyListenerBlock(id, &addr, listenerQueue, deviceListenerBlock)
            }
        }
    }

    private func deviceListenerAddresses() -> [(AudioObjectPropertySelector, AudioObjectPropertyScope, AudioObjectPropertyElement)] {
        [
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, 1),
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        ]
    }

    private func handleSystemChange() {
        let previous = observedDeviceID
        refreshDevices()
        let current = defaultOutputDeviceID
        if current != previous {
            removeDeviceListeners(for: previous)
            installDeviceListeners(for: current)
        }
        dispatch(onDeviceListChange)
    }

    private func handleVolumeChange() {
        dispatch(onVolumeChange)
    }

    private func dispatch(_ callback: (() -> Void)?) {
        if Thread.isMainThread {
            callback?()
        } else {
            DispatchQueue.main.async { callback?() }
        }
    }

    // MARK: - Property helpers

    private func stringProperty(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = ref?.takeRetainedValue() else {
            return nil
        }
        return value as String
    }

    private func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &addr) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }
}
