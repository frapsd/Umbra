/// The rules for which backlight levels DDCService must still put back. Kept
/// free of IOKit and UserDefaults so they can be tested without a monitor.
///
/// Levels are keyed by `DDCService.Display.persistenceKey`. A level stays on the
/// ledger until the display itself reports it back: losing it while the
/// backlight is still at 0 leaves nothing to restore from.
enum BrightnessLedger {

    /// Levels to persist before dimming. A level that is still pending wins over
    /// the one just read: it means the backlight was never restored, so the
    /// display is reporting Umbra's own 0, not the user's brightness.
    static func recording(_ current: [String: Int], over pending: [String: Int]) -> [String: Int] {
        pending.merging(current) { pendingLevel, _ in pendingLevel }
    }

    /// What must stay pending after a restore pass: every level not confirmed on
    /// its display, including those of displays that were not found at all.
    static func remaining(_ pending: [String: Int], confirmed: Set<String>) -> [String: Int] {
        pending.filter { !confirmed.contains($0.key) }
    }
}
