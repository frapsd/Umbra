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
        var levels = pending
        for (key, level) in current where pendingKey(for: key, in: pending) == nil {
            levels[key] = level
        }
        return levels
    }

    /// The pending key that belongs to the display keyed `key`, if any.
    ///
    /// The model half of a key comes from the DDC capabilities string, which a
    /// busy display can fail to return, turning "0|PA278CV" into "0|". An
    /// unknown model contradicts nothing, so on either side it matches on the
    /// index alone; two known models still have to agree. An exact key wins.
    static func pendingKey(for key: String, in pending: [String: Int]) -> String? {
        if pending[key] != nil { return key }
        let (index, model) = split(key)
        return pending.keys.sorted().first { candidate in
            let (candidateIndex, candidateModel) = split(candidate)
            return candidateIndex == index && (model.isEmpty || candidateModel.isEmpty)
        }
    }

    /// What must stay pending after a restore pass: every level not confirmed on
    /// its display, including those of displays that were not found at all.
    static func remaining(_ pending: [String: Int], confirmed: Set<String>) -> [String: Int] {
        pending.filter { !confirmed.contains($0.key) }
    }

    private static func split(_ key: String) -> (index: Substring, model: Substring) {
        guard let bar = key.firstIndex(of: "|") else { return (key[...], "") }
        return (key[..<bar], key[key.index(after: bar)...])
    }
}
