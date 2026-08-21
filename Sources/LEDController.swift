import Foundation

/// Third blackout layer: the machine's status LED.
///
/// A glowing LED gives away that the Mac is awake even when every panel is
/// black, which defeats the point on a machine that is supposed to look idle.
///
/// Switching it needs root, which a menu bar app does not have and should not
/// ask for. Instead this drives a helper installed by
/// `Tools/install-led-helper.sh`, authorised by a sudoers rule scoped to that
/// one binary and four fixed arguments. If the helper is absent the layer
/// simply reports itself unavailable; nothing else degrades.
final class LEDController {

    static let helperPath = "/usr/local/libexec/umbra-led"

    enum State: String {
        case on, off, unknown
    }

    /// Installed *and* callable without a password. Both halves matter: the
    /// binary can exist while the sudoers rule is missing, in which case every
    /// call would silently block on a password prompt that has nowhere to go.
    private(set) var isAvailable = false

    func refreshAvailability() {
        guard FileManager.default.isExecutableFile(atPath: Self.helperPath) else {
            isAvailable = false
            return
        }
        isAvailable = run("status") != nil
    }

    var state: State {
        guard let output = run("status") else { return .unknown }
        let value = output
            .split(separator: "=", maxSplits: 1)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return State(rawValue: value) ?? .unknown
    }

    @discardableResult
    func turnOff() -> Bool { run("off") != nil }

    @discardableResult
    func turnOn() -> Bool { run("on") != nil }

    /// Stops overriding and lets the SMC firmware manage the LED again. Sent on
    /// quit, after switching the LED back on, so the machine is left as found.
    @discardableResult
    func handBackToFirmware() -> Bool { run("revert") != nil }

    // MARK: - Private

    private func run(_ command: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        // -n makes a missing rule fail immediately instead of waiting forever on
        // a password prompt that a background app can never answer.
        task.arguments = ["-n", Self.helperPath, command]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
