import AppKit
import Carbon

// Carbon event delivery: InstallApplicationEventHandler is a C macro and can't be imported
// into Swift. Call the underlying InstallEventHandler(GetApplicationEventTarget(), …) directly.
// This requires no Input Monitoring permission — the system routes the event specifically to
// the app that registered the hotkey.
private func carbonHotkeyCallback(
    _: EventHandlerCallRef?,
    _: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    DispatchQueue.main.async { HotkeyManager.shared.fire() }
    return noErr
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    var onFire: (() -> Void)?

    private(set) var keyCode: Int          // Carbon / NSEvent key code (same values)
    private(set) var carbonModifiers: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let defaultKeyCode = kVK_ANSI_R
    // ⌃⌥⌘ in Carbon modifier flags
    private static let defaultCarbonModifiers = UInt32(controlKey | optionKey | cmdKey)

    private init() {
        let d = UserDefaults.standard
        keyCode = d.object(forKey: "hk.keyCode") as? Int ?? HotkeyManager.defaultKeyCode
        // Migration guard: Carbon modifiers are ≤ 8192; old NSEvent rawValues are 100 000+.
        let raw = d.object(forKey: "hk.modifiers") as? Int ?? 0
        carbonModifiers = (raw > 0 && raw <= 8192)
            ? UInt32(raw)
            : HotkeyManager.defaultCarbonModifiers
    }

    // Call once at app launch.
    func setup() {
        installCarbonHandler()
        registerHotKey(keyCode: keyCode, modifiers: carbonModifiers)
    }

    // Called by the settings recorder (NSEvent types) — converts internally to Carbon.
    func update(keyCode newKey: UInt16, modifiers newMods: NSEvent.ModifierFlags) {
        unregisterHotKey()
        let newKeyInt = Int(newKey)
        let newCarbonMods = Self.carbonModifiers(from: newMods)
        keyCode = newKeyInt
        carbonModifiers = newCarbonMods
        UserDefaults.standard.set(newKeyInt, forKey: "hk.keyCode")
        UserDefaults.standard.set(Int(newCarbonMods), forKey: "hk.modifiers")
        registerHotKey(keyCode: newKeyInt, modifiers: newCarbonMods)
    }

    func fire() {
        onFire?()
    }

    var currentShortcutLabel: String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey)  != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey)   != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey)     != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    // MARK: - Private

    private func installCarbonHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            1,
            &spec,
            nil,
            &handlerRef
        )
    }

    private func registerHotKey(keyCode: Int, modifiers: UInt32) {
        var id = EventHotKeyID()
        id.signature = 0x46545258  // 'FTRX'
        id.id = 1
        RegisterEventHotKey(UInt32(keyCode), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    private func unregisterHotKey() {
        guard let ref = hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        hotKeyRef = nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    private func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: "A"; case kVK_ANSI_B: "B"; case kVK_ANSI_C: "C"
        case kVK_ANSI_D: "D"; case kVK_ANSI_E: "E"; case kVK_ANSI_F: "F"
        case kVK_ANSI_G: "G"; case kVK_ANSI_H: "H"; case kVK_ANSI_I: "I"
        case kVK_ANSI_J: "J"; case kVK_ANSI_K: "K"; case kVK_ANSI_L: "L"
        case kVK_ANSI_M: "M"; case kVK_ANSI_N: "N"; case kVK_ANSI_O: "O"
        case kVK_ANSI_P: "P"; case kVK_ANSI_Q: "Q"; case kVK_ANSI_R: "R"
        case kVK_ANSI_S: "S"; case kVK_ANSI_T: "T"; case kVK_ANSI_U: "U"
        case kVK_ANSI_V: "V"; case kVK_ANSI_W: "W"; case kVK_ANSI_X: "X"
        case kVK_ANSI_Y: "Y"; case kVK_ANSI_Z: "Z"
        case kVK_ANSI_0: "0"; case kVK_ANSI_1: "1"; case kVK_ANSI_2: "2"
        case kVK_ANSI_3: "3"; case kVK_ANSI_4: "4"; case kVK_ANSI_5: "5"
        case kVK_ANSI_6: "6"; case kVK_ANSI_7: "7"; case kVK_ANSI_8: "8"
        case kVK_ANSI_9: "9"
        case kVK_F1: "F1"; case kVK_F2: "F2"; case kVK_F3: "F3"; case kVK_F4: "F4"
        case kVK_F5: "F5"; case kVK_F6: "F6"; case kVK_F7: "F7"; case kVK_F8: "F8"
        case kVK_F9: "F9"; case kVK_F10: "F10"; case kVK_F11: "F11"; case kVK_F12: "F12"
        case kVK_Space: "Space"; case kVK_Return: "↩"; case kVK_Delete: "⌫"; case kVK_Tab: "⇥"
        default: "Key\(keyCode)"
        }
    }
}
