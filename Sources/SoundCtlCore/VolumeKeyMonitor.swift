import AppKit
import CoreGraphics

/// Captures the hardware volume keys (volume up / down / mute) via a
/// `CGEventTap` on the system-defined media-key events. The handler decides
/// whether to consume each key (so the OS doesn't also act on it). Requires
/// Accessibility permission — `start()` returns false when it isn't granted.
final class VolumeKeyMonitor {

    enum Key { case up, down, mute }

    /// Called for each volume key. `isDown` is true on press (and key repeats);
    /// return true to consume the event (we handled it), false to pass it on to
    /// the system. The same decision should be returned for the matching key-up
    /// so the system never sees a stray half-press.
    var handler: ((Key, _ isDown: Bool, _ isRepeat: Bool) -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // NX_KEYTYPE_* media-key codes carried in an NSSystemDefined event's data1.
    private static let soundUp = 0
    private static let soundDown = 1
    private static let mute = 7
    private static let systemDefinedType: UInt32 = 14   // NSEvent.EventType.systemDefined

    var isActive: Bool { eventTap != nil }

    /// Installs the tap on the current run loop. Call on the main thread.
    /// Returns false if Accessibility permission is missing (tap can't be made).
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<VolumeKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << Self.systemDefinedType),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables the tap if a callback is slow or on user input;
        // re-enable and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let isDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        let key: Key
        switch keyCode {
        case Self.soundUp: key = .up
        case Self.soundDown: key = .down
        case Self.mute: key = .mute
        default: return Unmanaged.passUnretained(event)
        }

        let consume = handler?(key, isDown, isRepeat) ?? false
        return consume ? nil : Unmanaged.passUnretained(event)
    }
}
