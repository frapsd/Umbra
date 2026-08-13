import Foundation
import IOKit

// MARK: - Private IOAVService bridge

/// DDC/CI on Apple Silicon does not go through IOFramebuffer (that is the Intel
/// path). It goes through the display coprocessor's AV services, reachable only
/// via these unexported IOKit symbols — the same route MonitorControl and Lunar
/// take. Resolved with dlsym so a future macOS that drops them degrades to
/// "no DDC" instead of failing to launch.
private enum IOAV {
    typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)

    private static func load<T>(_ name: String) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    static let createWithService: CreateWithServiceFn? = load("IOAVServiceCreateWithService")
    static let readI2C: I2CFn? = load("IOAVServiceReadI2C")
    static let writeI2C: I2CFn? = load("IOAVServiceWriteI2C")

    static var isAvailable: Bool {
        createWithService != nil && readI2C != nil && writeI2C != nil
    }
}

// MARK: - Packet framing

private enum DDC {
    static let chipAddress: UInt32 = 0x37
    static let sourceAddress: UInt32 = 0x51

    static let vcpLuminance: UInt8 = 0x10

    /// VCP 0xD6 (power mode) is deliberately unused. Measured on an ASUS PA278CV
    /// over USB-C: sending 0xD6=0x05 does not put the panel in standby, it drops
    /// the link entirely — macOS went from two active displays to one, the AV
    /// service disappeared, and no wake command could be delivered afterwards.
    /// Beyond needing a physical button press, a vanishing display makes macOS
    /// reflow every window onto the survivors, which is exactly what must not
    /// happen mid remote session. Luminance is the only safe hardware lever.

    /// A DDC request on the wire is `0x6E 0x51 <0x80|len> <payload…> <checksum>`.
    /// `IOAVServiceWriteI2C` contributes the first two bytes itself through its
    /// chipAddress and dataAddress arguments, so the buffer must start at the
    /// length byte — repeating 0x51 inside the payload makes displays answer
    /// with a null message (`6E 80 BE`) instead of data.
    static func request(_ payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [UInt8(0x80 | payload.count)] + payload
        var checksum: UInt8 = 0x6E ^ UInt8(sourceAddress)
        for byte in packet { checksum ^= byte }
        packet.append(checksum)
        return packet
    }
}

// MARK: - Service

/// Optional "deeper black" layer. Where a display answers DDC/CI, its physical
/// backlight is driven to zero on top of the gamma blackout, removing the glow
/// that gamma alone leaves behind.
///
/// Unlike the gamma layer this one is not self-healing — a display left at
/// brightness 0 stays there if this process dies — so the pre-blackout levels
/// are persisted to disk and reapplied on the next launch.
final class DDCService {

    struct Display {
        let service: CFTypeRef
        let index: Int
        let model: String
        let responds: Bool
        /// Brightness read at probe time; nil when the display does not expose 0x10.
        let luminance: UInt16?
        let maxLuminance: UInt16

        var canDim: Bool { responds && luminance != nil }

        var label: String {
            model.isEmpty ? "Display \(index + 1)" : model
        }

        /// Stable enough to match a display across launches for brightness recovery.
        var persistenceKey: String { "\(index)|\(model)" }

        var statusText: String {
            guard responds else { return "\(label): no DDC — backlight glow will remain" }
            guard canDim else { return "\(label): DDC responds, no brightness control" }
            return "\(label): backlight controllable"
        }
    }

    private(set) var displays: [Display] = []

    /// Brightness levels captured before dimming, so they survive a crash.
    private static let restoreKey = "ddcBrightnessToRestore"

    var isAvailable: Bool { IOAV.isAvailable }
    var controllable: [Display] { displays.filter(\.canDim) }

    // MARK: Discovery

    /// Enumerates external AV services and probes each one. Slow (a few hundred
    /// milliseconds per display) — call it off the main thread.
    func refresh() {
        guard IOAV.isAvailable else { displays = []; return }

        var found: [Display] = []
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return }

        var index = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }

            let location = IORegistryEntryCreateCFProperty(
                entry, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            // Built-in panels are driven through DisplayServices, not DDC.
            guard location == "External" else { continue }

            guard let service = IOAV.createWithService?(kCFAllocatorDefault, entry)?.takeRetainedValue() else {
                index += 1
                continue
            }

            let capabilities = readCapabilities(service)
            let brightness = readVCP(service, DDC.vcpLuminance)

            found.append(Display(
                service: service,
                index: index,
                model: Self.parseModel(capabilities),
                responds: !capabilities.isEmpty || brightness != nil,
                luminance: brightness?.current,
                maxLuminance: brightness?.max ?? 100
            ))
            index += 1
        }
        IOObjectRelease(iterator)
        displays = found
    }

    // MARK: Brightness control

    /// Drives every controllable backlight to zero, recording the current levels
    /// on disk first so an abrupt exit can still be undone on the next launch.
    /// Returns the number of displays dimmed.
    @discardableResult
    func dimAll() -> Int {
        var levels: [String: Int] = [:]
        var dimmed = 0

        for display in controllable {
            // Re-read rather than trust the probe: the user may have adjusted the
            // monitor's own buttons since discovery.
            let current = readVCP(display.service, DDC.vcpLuminance)?.current ?? display.luminance ?? display.maxLuminance
            levels[display.persistenceKey] = Int(current)
            if writeVCP(display.service, DDC.vcpLuminance, 0) { dimmed += 1 }
        }

        UserDefaults.standard.set(levels, forKey: Self.restoreKey)
        return dimmed
    }

    /// Puts the recorded brightness back. Returns the number of displays restored.
    @discardableResult
    func restoreBrightness() -> Int {
        let levels = UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: Int] ?? [:]
        guard !levels.isEmpty else { return 0 }

        var restored = 0
        for display in controllable {
            guard let level = levels[display.persistenceKey] else { continue }
            if writeVCP(display.service, DDC.vcpLuminance, UInt16(clamping: level)) { restored += 1 }
        }

        UserDefaults.standard.removeObject(forKey: Self.restoreKey)
        return restored
    }

    /// True when a previous run ended without restoring brightness.
    var hasPendingRestore: Bool {
        !((UserDefaults.standard.dictionary(forKey: Self.restoreKey) as? [String: Int]) ?? [:]).isEmpty
    }

    /// Current brightness per display, for the self-test.
    func brightnessLevels() -> [(label: String, level: UInt16?)] {
        displays.map { ($0.label, readVCP($0.service, DDC.vcpLuminance)?.current) }
    }

    // MARK: - VCP primitives

    @discardableResult
    private func writeVCP(_ service: CFTypeRef, _ vcp: UInt8, _ value: UInt16, cycles: Int = 2) -> Bool {
        guard let writeI2C = IOAV.writeI2C else { return false }
        var succeeded = false
        // DDC has no acknowledgement for Set commands and displays drop packets
        // under load, so the write is repeated rather than verified.
        for _ in 0 ..< cycles {
            var packet = DDC.request([0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
            let length = UInt32(packet.count)
            let result = packet.withUnsafeMutableBytes {
                writeI2C(service, DDC.chipAddress, DDC.sourceAddress, $0.baseAddress!, length)
            }
            if result == KERN_SUCCESS { succeeded = true }
            usleep(20_000)
        }
        return succeeded
    }

    private func readVCP(_ service: CFTypeRef, _ vcp: UInt8, attempts: Int = 3) -> (current: UInt16, max: UInt16)? {
        guard let writeI2C = IOAV.writeI2C, let readI2C = IOAV.readI2C else { return nil }

        for _ in 0 ..< attempts {
            var packet = DDC.request([0x01, vcp])
            let length = UInt32(packet.count)
            let wrote = packet.withUnsafeMutableBytes {
                writeI2C(service, DDC.chipAddress, DDC.sourceAddress, $0.baseAddress!, length)
            }
            guard wrote == KERN_SUCCESS else { usleep(30_000); continue }
            usleep(50_000)

            var reply = [UInt8](repeating: 0, count: 12)
            let replyLength = UInt32(reply.count)
            let read = reply.withUnsafeMutableBytes {
                readI2C(service, DDC.chipAddress, DDC.sourceAddress, $0.baseAddress!, replyLength)
            }
            guard read == KERN_SUCCESS else { usleep(30_000); continue }

            // 6E 88 02 <result> <vcp> <type> <maxHi> <maxLo> <curHi> <curLo> <chk>
            guard reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
                  reply[3] == 0x00, reply[4] == vcp
            else { usleep(30_000); continue }

            let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            return (current, maxValue)
        }
        return nil
    }

    /// Reads the DDC capabilities string in chunks. Doubles as the liveness probe:
    /// a display that returns one is definitely talking DDC.
    private func readCapabilities(_ service: CFTypeRef) -> String {
        guard let writeI2C = IOAV.writeI2C, let readI2C = IOAV.readI2C else { return "" }

        var bytes = [UInt8]()
        var offset: UInt16 = 0

        for _ in 0 ..< 32 {
            var packet = DDC.request([0xF3, UInt8(offset >> 8), UInt8(offset & 0xFF)])
            let length = UInt32(packet.count)
            guard packet.withUnsafeMutableBytes({
                writeI2C(service, DDC.chipAddress, DDC.sourceAddress, $0.baseAddress!, length)
            }) == KERN_SUCCESS else { break }
            usleep(60_000)

            var reply = [UInt8](repeating: 0, count: 64)
            let replyLength = UInt32(reply.count)
            guard reply.withUnsafeMutableBytes({
                readI2C(service, DDC.chipAddress, DDC.sourceAddress, $0.baseAddress!, replyLength)
            }) == KERN_SUCCESS else { break }

            // 6E <0x80|len> E3 <offsetHi> <offsetLo> <payload…> <checksum>
            guard reply[0] == 0x6E, reply[2] == 0xE3 else { break }
            let payloadLength = Int(reply[1] & 0x7F)
            guard payloadLength > 3 else { break }

            let end = min(2 + payloadLength, reply.count)
            guard end > 5 else { break }
            let payload = Array(reply[5 ..< end])
            guard !payload.isEmpty else { break }

            bytes += payload
            offset += UInt16(payload.count)
            usleep(40_000)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - Capabilities parsing

    /// Pulls `model(PA278CV)` out of the capabilities string.
    static func parseModel(_ capabilities: String) -> String {
        guard let range = capabilities.range(of: "model(") else { return "" }
        let tail = capabilities[range.upperBound...]
        guard let close = tail.firstIndex(of: ")") else { return "" }
        return String(tail[..<close]).trimmingCharacters(in: .whitespaces)
    }
}
