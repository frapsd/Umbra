// Run with ./test.sh. Plain executable rather than XCTest, which the Command
// Line Tools do not ship; these rules need no display, so CI can run them.

import Foundation

var failures = 0

func check(_ condition: Bool, _ name: String) {
    print(condition ? "PASS  \(name)" : "FAIL  \(name)")
    if !condition { failures += 1 }
}

// The incident that prompted the ledger: a restore whose write did not land
// dropped the saved level, leaving the monitor at 0 with nothing to put back.
check(
    BrightnessLedger.remaining(["0|PA278CV": 50], confirmed: []) == ["0|PA278CV": 50],
    "a level not confirmed on its display stays pending"
)
check(
    BrightnessLedger.remaining(["0|PA278CV": 50], confirmed: ["0|PA278CV"]).isEmpty,
    "a confirmed level is cleared"
)
check(
    BrightnessLedger.remaining(["0|PA278CV": 50, "1|U2720Q": 80], confirmed: ["0|PA278CV"]) == ["1|U2720Q": 80],
    "a display absent during restore keeps its level"
)

// Dimming again while a level is still pending reads Umbra's own 0 back from
// the monitor; recording that would make 0 the level to restore.
check(
    BrightnessLedger.recording(["0|PA278CV": 0], over: ["0|PA278CV": 50]) == ["0|PA278CV": 50],
    "a pending level wins over the dimmed reading"
)
check(
    BrightnessLedger.recording(["0|PA278CV": 70, "1|U2720Q": 80], over: [:]) == ["0|PA278CV": 70, "1|U2720Q": 80],
    "with nothing pending, the current levels are recorded"
)
check(
    BrightnessLedger.recording(["0|PA278CV": 0], over: ["1|U2720Q": 80]) == ["0|PA278CV": 0, "1|U2720Q": 80],
    "a pending level for another display is kept"
)

// The model comes from the DDC capabilities string, which a busy display can
// fail to return; the key then reads "0|" instead of "0|PA278CV". An unknown
// model contradicts nothing, so the display index alone has to match.
check(
    BrightnessLedger.pendingKey(for: "0|", in: ["0|PA278CV": 50]) == "0|PA278CV",
    "a display whose model went unread finds its level by index"
)
check(
    BrightnessLedger.pendingKey(for: "0|PA278CV", in: ["0|": 50]) == "0|",
    "a level saved without a model is found once the model reads"
)
check(
    BrightnessLedger.pendingKey(for: "0|U2720Q", in: ["0|PA278CV": 50]) == nil,
    "a different model on the same index is not the same display"
)
check(
    BrightnessLedger.pendingKey(for: "1|", in: ["0|PA278CV": 50]) == nil,
    "a different index is not the same display"
)
check(
    BrightnessLedger.pendingKey(for: "0|", in: ["0|": 40, "0|PA278CV": 50]) == "0|",
    "an exact key wins over a loose match"
)
check(
    BrightnessLedger.recording(["0|": 0], over: ["0|PA278CV": 50]) == ["0|PA278CV": 50],
    "dimming with the model unread keeps the pending level, without a stray 0"
)

print(failures == 0 ? "\nall passed" : "\n\(failures) failed")
exit(failures == 0 ? 0 : 1)
