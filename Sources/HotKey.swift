import Carbon
import Foundation

/// A key plus modifier combination, resolvable from user defaults.
struct HotKeyCombination {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = HotKeyCombination(
        keyCode: UInt32(kVK_ANSI_B),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    /// Read from `UserDefaults` so the combination can be changed without a
    /// preferences window:
    ///
    ///     defaults write io.github.frapsd.Umbra hotKeyCode -int 35     # P
    ///     defaults write io.github.frapsd.Umbra hotKeyModifiers -int 2304
    ///
    /// Values are Carbon virtual key codes and Carbon modifier masks.
    static var configured: HotKeyCombination {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hotKeyCode") != nil else { return .default }
        let code = UInt32(defaults.integer(forKey: "hotKeyCode"))
        let modifiers = defaults.object(forKey: "hotKeyModifiers") != nil
            ? UInt32(defaults.integer(forKey: "hotKeyModifiers"))
            : HotKeyCombination.default.modifiers
        return HotKeyCombination(keyCode: code, modifiers: modifiers)
    }

    /// Menu-style rendering, e.g. `⌃⌥⌘B`.
    var display: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.name(for: keyCode)
    }

    /// Carbon virtual key codes address physical keys, so this table holds for
    /// any QWERTY-derived layout. Unmapped keys degrade to their number rather
    /// than pretending to know.
    private static func name(for keyCode: UInt32) -> String {
        let keys: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
            UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
            UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
            UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
            UInt32(kVK_Space): "Space", UInt32(kVK_Escape): "Esc",
        ]
        return keys[keyCode] ?? "#\(keyCode)"
    }
}

/// System-wide hotkey via Carbon's `RegisterEventHotKey`.
///
/// Deliberately not `NSEvent.addGlobalMonitorForEvents`: that route requires the
/// Accessibility permission, which would mean granting an app that only dims
/// screens the right to observe every keystroke on the machine. Carbon hotkeys
/// need no permission at all — the main reason this app asks for nothing.
final class HotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil when the combination is already claimed by another app.
    init?(_ combination: HotKeyCombination, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userInfo in
                guard let userInfo else { return noErr }
                Unmanaged<HotKey>.fromOpaque(userInfo).takeUnretainedValue().action()
                return noErr
            },
            1, &eventType, context, &handlerRef
        )
        guard handlerStatus == noErr else { return nil }

        let identifier = EventHotKeyID(signature: OSType(0x554D4252), id: 1) // 'UMBR'
        let registerStatus = RegisterEventHotKey(
            combination.keyCode, combination.modifiers, identifier,
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        guard registerStatus == noErr, hotKeyRef != nil else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
