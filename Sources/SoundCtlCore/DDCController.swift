import Foundation
import IOKit
import CoreAudio
import CoreGraphics
import CDDC

/// C callback for display reconfiguration; forwards to the DDCController in
/// `userInfo`. Acts only on the "after" pass (no begin-configuration flag).
private let ddcDisplayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, userInfo in
    guard let userInfo, !flags.contains(.beginConfigurationFlag) else { return }
    Unmanaged<DDCController>.fromOpaque(userInfo).takeUnretainedValue().handleDisplayReconfiguration()
}

/// Maps an audio output device to a physical display reachable over DDC/CI and
/// provides volume read/write via the private IOAVService API (Apple Silicon).
///
/// The IORegistry walk and I2C packet format follow MonitorControl's proven
/// Arm64 implementation, simplified: instead of EDID/CoreDisplay scoring we map
/// by the display's ProductName (with a single-external-display fallback), which
/// is robust for the common one-monitor case.
final class DDCController {

    private struct ServiceInfo {
        let productName: String
        let service: CFTypeRef
    }

    private var services: [ServiceInfo] = []
    private var cache: [AudioDeviceID: DDCDisplay] = [:]

    /// Invoked (main thread) after the display set changes, so callers can
    /// re-seed cached levels and re-render.
    var onDisplaysChanged: (() -> Void)?

    init() {
        discover()
        CGDisplayRegisterReconfigurationCallback(ddcDisplayReconfigurationCallback,
                                                 Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(ddcDisplayReconfigurationCallback,
                                               Unmanaged.passUnretained(self).toOpaque())
    }

    func discover() {
        services = Self.collectExternalServices()
        cache.removeAll()
    }

    /// Re-discover when a monitor is plugged/unplugged so we never keep talking
    /// to a stale `IOAVService`.
    func handleDisplayReconfiguration() {
        discover()
        onDisplaysChanged?()
    }

    /// Returns a DDC handle if `device` corresponds to an external display we can
    /// talk to, otherwise nil (callers then fall back to the CoreAudio path).
    func display(matching device: AudioDevice) -> DDCDisplay? {
        guard device.isDisplayTransport else { return nil }
        if let cached = cache[device.id] { return cached }
        if services.isEmpty { discover() }

        let lowerName = device.name.lowercased()
        // Prefer an exact product-name match, then a containment match, and only
        // fall back to "the single external display" when there is exactly one
        // (so two identical monitors never silently mis-route).
        let exact = services.first { !$0.productName.isEmpty && $0.productName.lowercased() == lowerName }
        let contains = services.first {
            !$0.productName.isEmpty &&
            (lowerName.contains($0.productName.lowercased()) ||
             $0.productName.lowercased().contains(lowerName))
        }
        let match = exact ?? contains ?? (services.count == 1 ? services.first : nil)
        guard let info = match else { return nil }

        let display = DDCDisplay(service: info.service)
        cache[device.id] = display
        return display
    }

    /// Debug helper: returns discovered (productName, display) pairs.
    func debugDisplays() -> [(name: String, display: DDCDisplay)] {
        if services.isEmpty { discover() }
        return services.map { ($0.productName, DDCDisplay(service: $0.service)) }
    }

    // MARK: - IORegistry discovery

    private static func collectExternalServices() -> [ServiceInfo] {
        var result: [ServiceInfo] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return result }
        defer { IOObjectRelease(root) }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            root, "IOService", IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        let framebufferKeys = ["AppleCLCD2", "IOMobileFramebufferShim"]
        let proxyKey = "DCPAVServiceProxy"
        var pendingProductName = ""

        while let obj = iterateToObject(of: framebufferKeys + [proxyKey], iterator: &iterator) {
            if framebufferKeys.contains(obj.name) {
                pendingProductName = productName(of: obj.entry)
                IOObjectRelease(obj.entry)
            } else if obj.name == proxyKey {
                if let service = externalService(of: obj.entry) {
                    result.append(ServiceInfo(productName: pendingProductName, service: service))
                }
                pendingProductName = ""
                IOObjectRelease(obj.entry)
            } else {
                IOObjectRelease(obj.entry)
            }
        }
        return result
    }

    private static func iterateToObject(of interests: [String],
                                        iterator: inout io_iterator_t)
        -> (name: String, entry: io_service_t)? {
        let name = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { name.deallocate() }
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != MACH_PORT_NULL else { return nil }
            guard IORegistryEntryGetName(entry, name) == KERN_SUCCESS else {
                IOObjectRelease(entry)
                continue
            }
            let nameString = String(cString: name)
            if interests.contains(where: { nameString.contains($0) }) {
                return (nameString, entry)
            }
            IOObjectRelease(entry)
        }
    }

    private static func productName(of entry: io_service_t) -> String {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, IOOptionBits(0)),
            let attrs = raw.takeRetainedValue() as? NSDictionary,
            let product = attrs.value(forKey: "ProductAttributes") as? NSDictionary,
            let name = product.value(forKey: "ProductName") as? String else {
            return ""
        }
        return name
    }

    private static func externalService(of entry: io_service_t) -> CFTypeRef? {
        guard let raw = IORegistryEntryCreateCFProperty(
            entry, "Location" as CFString, kCFAllocatorDefault, IOOptionBits(0)),
            let location = raw.takeRetainedValue() as? String,
            location == "External" else {
            return nil
        }
        return IOAVServiceCreateWithService(kCFAllocatorDefault, entry)?.takeRetainedValue()
    }
}

/// A single DDC/CI-controllable display. Volume is VCP 0x62, mute is VCP 0x8D.
/// Writes are coalesced onto a background queue so rapid slider drags never
/// block the main thread.
final class DDCDisplay {
    private let service: CFTypeRef
    private var maxValue: UInt16 = 100

    private let ioQueue = DispatchQueue(label: "com.lmqferreira.soundctl.ddc")
    private var pendingVolume: Float?
    private var draining = false

    private static let ddc7BitAddress: UInt8 = 0x37
    private static let ddcDataAddress: UInt8 = 0x51
    private static let vcpVolume: UInt8 = 0x62
    private static let vcpAudioMute: UInt8 = 0x8D

    init(service: CFTypeRef) {
        self.service = service
    }

    /// Synchronous read (used on popover open / drag end), serialized with
    /// writes on the I/O queue so the two never hit the I2C bus concurrently.
    func readVolume() -> Float? {
        ioQueue.sync {
            guard let result = read(command: Self.vcpVolume) else { return nil }
            maxValue = max(1, result.max)
            return Float(result.current) / Float(max(1, result.max))
        }
    }

    /// Non-blocking, coalesced write: only the most recent target is sent.
    func writeVolume(_ value: Float) {
        let clamped = max(0, min(1, value))
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.pendingVolume = clamped
            guard !self.draining else { return }
            self.draining = true
            while let target = self.pendingVolume {
                self.pendingVolume = nil
                let raw = UInt16((target * Float(self.maxValue)).rounded())
                _ = self.write(command: Self.vcpVolume, value: raw)
            }
            self.draining = false
        }
    }

    func setMute(_ muted: Bool) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            // MCCS VCP 0x8D: 1 = mute, 2 = unmute.
            _ = self.write(command: Self.vcpAudioMute, value: muted ? 1 : 2)
        }
    }

    // MARK: - DDC/CI transport (ported from MonitorControl Arm64DDC)

    private func read(command: UInt8) -> (current: UInt16, max: UInt16)? {
        var send: [UInt8] = [command]
        var reply = [UInt8](repeating: 0, count: 11)
        guard communicate(send: &send, reply: &reply) else { return nil }
        let max = UInt16(reply[6]) * 256 + UInt16(reply[7])
        let current = UInt16(reply[8]) * 256 + UInt16(reply[9])
        return (current, max)
    }

    @discardableResult
    private func write(command: UInt8, value: UInt16) -> Bool {
        var send: [UInt8] = [command, UInt8(value >> 8), UInt8(value & 255)]
        var reply: [UInt8] = []
        return communicate(send: &send, reply: &reply)
    }

    private func communicate(send: inout [UInt8], reply: inout [UInt8]) -> Bool {
        let dataAddress = Self.ddcDataAddress
        var success = false
        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        packet[packet.count - 1] = Self.checksum(
            chk: send.count == 1 ? Self.ddc7BitAddress << 1 : Self.ddc7BitAddress << 1 ^ dataAddress,
            data: &packet, start: 0, end: packet.count - 2)

        for _ in 1 ... 5 {
            for _ in 1 ... 2 {
                usleep(10000)
                success = IOAVServiceWriteI2C(
                    service, UInt32(Self.ddc7BitAddress), UInt32(dataAddress),
                    &packet, UInt32(packet.count)) == 0
            }
            if !reply.isEmpty {
                usleep(50000)
                if IOAVServiceReadI2C(
                    service, UInt32(Self.ddc7BitAddress), 0, &reply, UInt32(reply.count)) == 0 {
                    success = Self.checksum(chk: 0x50, data: &reply, start: 0, end: reply.count - 2)
                        == reply[reply.count - 1]
                }
            }
            if success { return true }
            usleep(20000)
        }
        return success
    }

    static func checksum(chk: UInt8, data: inout [UInt8], start: Int, end: Int) -> UInt8 {
        var result = chk
        for i in start ... end {
            result ^= data[i]
        }
        return result
    }
}
