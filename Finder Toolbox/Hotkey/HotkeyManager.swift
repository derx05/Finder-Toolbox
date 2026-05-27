import AppKit
import Carbon

// Carbon event delivery: InstallApplicationEventHandler is a C macro and can't be imported
// into Swift. Call the underlying InstallEventHandler(GetApplicationEventTarget(), …) directly.
// This requires no Input Monitoring permission — the system routes the event specifically to
// the app that registered the hotkey.
private func carbonHotkeyCallback(
    _: EventHandlerCallRef?,
    _ event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    if let event {
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
    }
    let id = hotKeyID.id
    DispatchQueue.main.async { HotkeyManager.shared.fire(id: id) }
    return noErr
}

final class HotkeyManager {
    static let shared = HotkeyManager()

    /// Fired by the primary (non-recursive / "ask") hotkey.
    var onFire: (() -> Void)?
    /// Fired by the secondary (recursive) hotkey, when enabled.
    var onSecondaryFire: (() -> Void)?

    /// Primary hotkey.
    private(set) var keyCode: Int
    private(set) var carbonModifiers: UInt32

    /// Secondary hotkey (recursive). Only registered when `secondaryEnabled` is true.
    private(set) var secondaryEnabled: Bool
    private(set) var secondaryKeyCode: Int
    private(set) var secondaryCarbonModifiers: UInt32

    private var primaryRef: EventHotKeyRef?
    private var secondaryRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private static let primaryID: UInt32 = 1
    private static let secondaryID: UInt32 = 2

    private static let defaultKeyCode = kVK_ANSI_R
    // ⌃⌥⌘ in Carbon modifier flags
    private static let defaultCarbonModifiers = UInt32(controlKey | optionKey | cmdKey)
    private static let defaultSecondaryKeyCode = kVK_ANSI_R
    // ⌃⌥⌘⇧ in Carbon modifier flags
    private static let defaultSecondaryCarbonModifiers = UInt32(controlKey | optionKey | cmdKey | shiftKey)

    private init() {
        let d = UserDefaults.standard
        keyCode = d.object(forKey: DefaultsKeys.hotkeyKeyCode) as? Int ?? HotkeyManager.defaultKeyCode
        // Migration guard: Carbon modifiers are ≤ 8192; old NSEvent rawValues are 100 000+.
        let raw = d.object(forKey: DefaultsKeys.hotkeyModifiers) as? Int ?? 0
        carbonModifiers = (raw > 0 && raw <= 8192)
            ? UInt32(raw)
            : HotkeyManager.defaultCarbonModifiers

        secondaryEnabled = d.bool(forKey: DefaultsKeys.secondaryHotkeyEnabled)
        secondaryKeyCode = d.object(forKey: DefaultsKeys.secondaryHotkeyKeyCode) as? Int ?? HotkeyManager.defaultSecondaryKeyCode
        let rawSecondary = d.object(forKey: DefaultsKeys.secondaryHotkeyModifiers) as? Int ?? 0
        secondaryCarbonModifiers = (rawSecondary > 0 && rawSecondary <= 8192)
            ? UInt32(rawSecondary)
            : HotkeyManager.defaultSecondaryCarbonModifiers
    }

    // Call once at app launch.
    func setup() {
        installCarbonHandler()
        registerPrimary()
        if secondaryEnabled { registerSecondary() }
    }

    // Called by the settings recorder (NSEvent types) — converts internally to Carbon.
    func update(keyCode newKey: UInt16, modifiers newMods: NSEvent.ModifierFlags) {
        unregisterPrimary()
        let newKeyInt = Int(newKey)
        let newCarbonMods = Self.carbonModifiers(from: newMods)
        keyCode = newKeyInt
        carbonModifiers = newCarbonMods
        UserDefaults.standard.set(newKeyInt, forKey: DefaultsKeys.hotkeyKeyCode)
        UserDefaults.standard.set(Int(newCarbonMods), forKey: DefaultsKeys.hotkeyModifiers)
        registerPrimary()
    }

    func updateSecondary(keyCode newKey: UInt16, modifiers newMods: NSEvent.ModifierFlags) {
        unregisterSecondary()
        let newKeyInt = Int(newKey)
        let newCarbonMods = Self.carbonModifiers(from: newMods)
        secondaryKeyCode = newKeyInt
        secondaryCarbonModifiers = newCarbonMods
        UserDefaults.standard.set(newKeyInt, forKey: DefaultsKeys.secondaryHotkeyKeyCode)
        UserDefaults.standard.set(Int(newCarbonMods), forKey: DefaultsKeys.secondaryHotkeyModifiers)
        if secondaryEnabled { registerSecondary() }
    }

    func setSecondaryEnabled(_ enabled: Bool) {
        guard enabled != secondaryEnabled else { return }
        secondaryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.secondaryHotkeyEnabled)
        if enabled { registerSecondary() } else { unregisterSecondary() }
    }

    func fire(id: UInt32) {
        switch id {
        case Self.primaryID:   onFire?()
        case Self.secondaryID: onSecondaryFire?()
        default: break
        }
    }

    var currentShortcutLabel: String {
        Self.label(keyCode: keyCode, carbonModifiers: carbonModifiers)
    }

    var secondaryShortcutLabel: String {
        Self.label(keyCode: secondaryKeyCode, carbonModifiers: secondaryCarbonModifiers)
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

    private func registerPrimary() {
        var id = EventHotKeyID()
        id.signature = 0x46545258  // 'FTRX'
        id.id = Self.primaryID
        RegisterEventHotKey(UInt32(keyCode), carbonModifiers, id, GetApplicationEventTarget(), 0, &primaryRef)
    }

    private func registerSecondary() {
        unregisterSecondary()
        var id = EventHotKeyID()
        id.signature = 0x46545258  // 'FTRX'
        id.id = Self.secondaryID
        RegisterEventHotKey(UInt32(secondaryKeyCode), secondaryCarbonModifiers, id, GetApplicationEventTarget(), 0, &secondaryRef)
    }

    private func unregisterPrimary() {
        guard let ref = primaryRef else { return }
        UnregisterEventHotKey(ref)
        primaryRef = nil
    }

    private func unregisterSecondary() {
        guard let ref = secondaryRef else { return }
        UnregisterEventHotKey(ref)
        secondaryRef = nil
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    private static func label(keyCode: Int, carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey)  != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey)   != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey)     != 0 { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: Int) -> String {
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
