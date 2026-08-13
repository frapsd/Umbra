import CoreGraphics
import Foundation

/// Non-interactive verification, run with `--selftest`.
///
/// Exists because this app's core is hardware I/O: "it compiled" says nothing
/// about whether a monitor actually went dark. Every check here asserts against
/// a value read back from the hardware rather than against a success return code.
enum SelfTest {

    static func run(includeDDCCycle: Bool) -> Int32 {
        var failures = 0

        section("Active displays")
        let displays = GammaBlanker.activeDisplays()
        if displays.isEmpty {
            fail("no active displays"); failures += 1
        } else {
            for display in displays {
                pass("id=\(display)  \(GammaBlanker.describe(display))")
            }
        }

        section("DDC/CI")
        let ddc = DDCService()
        if !ddc.isAvailable {
            fail("IOAVService symbols unavailable on this macOS"); failures += 1
        } else {
            pass("IOAVService symbols resolved")
            ddc.refresh()
            if ddc.displays.isEmpty {
                warn("no external AV services found")
            }
            for display in ddc.displays {
                if display.canDim {
                    pass("service #\(display.index)  \(display.label)  brightness \(display.luminance ?? 0)/\(display.maxLuminance)")
                } else if display.responds {
                    warn("service #\(display.index)  \(display.label)  responds but exposes no VCP 0x10")
                } else {
                    warn("service #\(display.index)  no DDC response — gamma blackout only")
                }
            }
        }

        section("Gamma cycle (verified by reading the hardware back)")
        let gamma = GammaBlanker()

        let before = displays.compactMap { gamma.peakGamma($0) }
        guard before.count == displays.count else {
            fail("could not read the starting gamma"); return 1
        }
        pass("starting gamma: \(format(before))")

        let blacked = gamma.blackout()
        if blacked != displays.count {
            fail("blacked out \(blacked)/\(displays.count) displays"); failures += 1
        } else {
            pass("blackout applied to \(blacked)/\(displays.count) displays")
        }

        Thread.sleep(forTimeInterval: 0.4)
        let during = displays.compactMap { gamma.peakGamma($0) }
        if during.allSatisfy({ $0 < 0.01 }) {
            pass("verified: gamma is zero on every display — \(format(during))")
        } else {
            fail("gamma NOT zeroed: \(format(during))"); failures += 1
        }

        gamma.restore()
        Thread.sleep(forTimeInterval: 0.4)
        let after = displays.compactMap { gamma.peakGamma($0) }
        if after.allSatisfy({ $0 > 0.9 }) {
            pass("verified: gamma restored — \(format(after))")
        } else {
            fail("gamma NOT restored: \(format(after))"); failures += 1
        }

        if includeDDCCycle {
            section("DDC backlight cycle")
            let targets = ddc.controllable
            if targets.isEmpty {
                warn("no display exposes brightness over DDC — skipped")
            } else {
                let originals = Dictionary(uniqueKeysWithValues: targets.map { ($0.label, $0.luminance ?? 0) })
                for target in targets { note("target: \(target.label) at \(originals[target.label] ?? 0)") }

                let dimmed = ddc.dimAll()
                if dimmed != targets.count {
                    fail("dimmed \(dimmed)/\(targets.count) displays"); failures += 1
                }
                Thread.sleep(forTimeInterval: 2)

                // The display count must not change. A display dropping off the
                // bus is the failure mode that made VCP 0xD6 unusable: macOS
                // reflows every window onto the survivors.
                let stillActive = GammaBlanker.activeDisplays().count
                if stillActive == displays.count {
                    pass("all \(stillActive) displays still attached to macOS")
                } else {
                    fail("active displays went from \(displays.count) to \(stillActive) — a monitor disconnected")
                    failures += 1
                }

                for (label, level) in ddc.brightnessLevels() where originals[label] != nil {
                    if level == 0 { pass("\(label): brightness 0 confirmed by the display") }
                    else if let level { fail("\(label): brightness \(level), expected 0"); failures += 1 }
                    else { fail("\(label): no response while dimmed"); failures += 1 }
                }

                let restored = ddc.restoreBrightness()
                note("restore sent to \(restored) displays")
                Thread.sleep(forTimeInterval: 2)

                for (label, level) in ddc.brightnessLevels() {
                    guard let original = originals[label] else { continue }
                    if level == original { pass("\(label): brightness back to \(original)") }
                    else if let level { fail("\(label): brightness \(level), expected \(original)"); failures += 1 }
                    else { fail("\(label): no response after restore"); failures += 1 }
                }
            }
        }

        section("Result")
        print(failures == 0 ? "  ALL CHECKS PASSED" : "  \(failures) CHECK(S) FAILED")
        return failures == 0 ? 0 : 1
    }

    // MARK: - Output

    private static func format(_ values: [CGGammaValue]) -> String {
        values.map { String(format: "%.3f", $0) }.joined(separator: ", ")
    }

    private static func section(_ title: String) { print("\n\(title)") }
    private static func pass(_ message: String) { print("  [ok]   \(message)") }
    private static func fail(_ message: String) { print("  [FAIL] \(message)") }
    private static func warn(_ message: String) { print("  [warn] \(message)") }
    private static func note(_ message: String) { print("  ...    \(message)") }
}
