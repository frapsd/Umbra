import AppKit
import CoreGraphics
import Foundation

/// Orchestrates the two blackout layers and owns the on/off state.
///
/// Layering matters in both directions: gamma goes to black first because it is
/// instantaneous, and comes back last because a panel woken over DDC needs a
/// second or two to relight — restoring gamma first would just mean staring at a
/// dark screen for longer.
final class BlackoutController {

    enum Mode: String {
        /// Gamma blackout plus DDC backlight to zero where supported. Darkest
        /// result that still keeps every display connected to macOS.
        case full
        /// Gamma only — never touches the monitors' own settings.
        case gammaOnly

        var title: String {
            switch self {
            case .full: return "Gamma + backlight to minimum"
            case .gammaOnly: return "Gamma only"
            }
        }
    }

    private let gamma = GammaBlanker()
    private let ddc = DDCService()

    /// DDC round trips take hundreds of milliseconds; keep them off the main thread.
    private let ddcQueue = DispatchQueue(label: "local.screenblackout.ddc", qos: .userInitiated)

    private(set) var isBlacked = false

    var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            // Leaving .full mid-blackout would strand the backlights at zero.
            if oldValue == .full, mode == .gammaOnly, isBlacked {
                ddcQueue.async { [ddc] in _ = ddc.restoreBrightness() }
            }
        }
    }

    /// Called on the main thread whenever the state changes, so the menu can redraw.
    var onChange: (() -> Void)?

    private var signalSources: [DispatchSourceSignal] = []

    init() {
        let stored = UserDefaults.standard.string(forKey: "mode")
        mode = stored.flatMap(Mode.init(rawValue:)) ?? .full

        installTerminationHandlers()
        observeDisplayReconfiguration()

        // Recover from a previous run that died with backlights at zero.
        ddcQueue.async { [ddc] in
            ddc.refresh()
            if ddc.hasPendingRestore { _ = ddc.restoreBrightness() }
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    // MARK: - Public API

    func toggle() {
        isBlacked ? restore() : blackout()
    }

    func blackout() {
        guard !isBlacked else { return }

        let blacked = gamma.blackout()
        guard blacked > 0 else {
            presentFailure()
            return
        }
        isBlacked = true
        onChange?()

        if mode == .full {
            ddcQueue.async { [ddc] in _ = ddc.dimAll() }
        }
    }

    func restore() {
        guard isBlacked else { return }
        isBlacked = false

        if mode == .full {
            // Brightness first: the backlight takes a moment to climb, and
            // restoring gamma before it would only show a dim desktop.
            ddcQueue.async { [ddc, gamma] in
                _ = ddc.restoreBrightness()
                DispatchQueue.main.async {
                    gamma.restore()
                    self.onChange?()
                }
            }
        } else {
            gamma.restore()
            onChange?()
        }
    }

    /// Restore synchronously, for app termination. Gamma is reverted by
    /// WindowServer anyway once this process exits, so the brightness restore is
    /// the part that actually matters here.
    func restoreNow() {
        guard isBlacked else { return }
        isBlacked = false
        if mode == .full { _ = ddc.restoreBrightness() }
        gamma.restore()
    }

    // MARK: - Diagnostics for the menu

    var ddcAvailable: Bool { ddc.isAvailable }
    var ddcDisplays: [DDCService.Display] { ddc.displays }
    var displayCount: Int { GammaBlanker.activeDisplays().count }

    func rescanDisplays(completion: @escaping () -> Void) {
        ddcQueue.async { [ddc] in
            ddc.refresh()
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Private

    private func presentFailure() {
        let alert = NSAlert()
        alert.messageText = "Could not black out the screens"
        alert.informativeText = """
            No display accepted the gamma change, which is very unusual. Try \
            unplugging and reconnecting the monitors, or restarting the Mac.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A monitor plugged in mid-blackout would otherwise stay lit, defeating the
    /// point. macOS also resets gamma on some reconfiguration events, so the
    /// blackout has to be re-asserted rather than assumed.
    private func observeDisplayReconfiguration() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback({ _, flags, userInfo in
            guard let userInfo else { return }
            // Only react once the change has landed.
            guard !flags.contains(.beginConfigurationFlag) else { return }
            let controller = Unmanaged<BlackoutController>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.gamma.syncAfterReconfiguration()
                controller.ddc.refresh()
                controller.onChange?()
            }
        }, context)
    }

    /// Handled through GCD rather than a raw `signal` handler so the cleanup runs
    /// in normal context and may safely touch IOKit.
    private func installTerminationHandlers() {
        for code in [SIGTERM, SIGINT, SIGHUP] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreNow()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
