import CoreGraphics
import Foundation

/// Universal blackout layer: zeroes each display's gamma transfer table.
///
/// The transfer table is applied at scanout, *after* the stage screen-capture
/// APIs read from. That is why a remote session (AnyDesk, Screen Sharing) keeps
/// receiving the real desktop while the physical panel shows black — the same
/// reason f.lux's tint never appears in a screenshot.
///
/// Safety property, verified with SIGKILL during design: WindowServer reverts a
/// client's gamma when that client dies. This layer therefore cannot strand the
/// user in the dark — `killall` from a remote session always brings the screens
/// back. Works on every display, including ones with no DDC/CI channel.
final class GammaBlanker {

    private struct Table {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
    }

    /// Gamma tables captured before blackout, keyed by display.
    private var saved: [CGDirectDisplayID: Table] = [:]

    private(set) var isBlacked = false

    private static let zeros = [CGGammaValue](repeating: 0, count: 256)

    // MARK: - Display enumeration

    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func describe(_ display: CGDirectDisplayID) -> String {
        let bounds = CGDisplayBounds(display)
        let kind = CGDisplayIsBuiltin(display) != 0 ? "built-in" : "external"
        let main = CGDisplayIsMain(display) != 0 ? ", main" : ""
        return String(format: "%.0f×%.0f (%@%@)", bounds.width, bounds.height, kind, main)
    }

    // MARK: - Blackout / restore

    /// Returns the number of displays that went black.
    @discardableResult
    func blackout() -> Int {
        var blacked = 0
        for display in Self.activeDisplays() {
            if saved[display] == nil, let table = readTable(display) {
                saved[display] = table
            }
            if zero(display) { blacked += 1 }
        }
        isBlacked = blacked > 0
        return blacked
    }

    func restore() {
        for (display, table) in saved {
            var red = table.red, green = table.green, blue = table.blue
            CGSetDisplayTransferByTable(display, UInt32(table.red.count), &red, &green, &blue)
        }
        saved.removeAll()
        // Belt and braces: also asks ColorSync to reassert the calibrated profile,
        // which covers displays whose saved table failed to read.
        CGDisplayRestoreColorSyncSettings()
        isBlacked = false
    }

    /// Called after a display is attached, detached, or reconfigured. Keeps a
    /// newly attached display from staying lit while everything else is black,
    /// and re-asserts the zero table because macOS resets gamma on some
    /// reconfiguration events.
    func syncAfterReconfiguration() {
        guard isBlacked else { return }
        let active = Set(Self.activeDisplays())

        // A display that went away takes its saved table with it.
        saved = saved.filter { active.contains($0.key) }

        for display in active {
            if saved[display] == nil, let table = readTable(display) {
                saved[display] = table
            }
            _ = zero(display)
        }
    }

    // MARK: - Verification support

    /// Current maximum red-channel gamma value, used by the self-test to prove a
    /// blackout or a restore actually landed rather than merely returning success.
    func peakGamma(_ display: CGDirectDisplayID) -> CGGammaValue? {
        readTable(display)?.red.max()
    }

    // MARK: - Private

    private func readTable(_ display: CGDirectDisplayID) -> Table? {
        let capacity = Int(CGDisplayGammaTableCapacity(display))
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: capacity)
        var green = [CGGammaValue](repeating: 0, count: capacity)
        var blue = [CGGammaValue](repeating: 0, count: capacity)
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, UInt32(capacity), &red, &green, &blue, &count) == .success,
              count > 0
        else { return nil }
        let n = Int(count)
        return Table(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    private func zero(_ display: CGDirectDisplayID) -> Bool {
        var red = Self.zeros, green = Self.zeros, blue = Self.zeros
        return CGSetDisplayTransferByTable(display, UInt32(Self.zeros.count), &red, &green, &blue) == .success
    }
}
