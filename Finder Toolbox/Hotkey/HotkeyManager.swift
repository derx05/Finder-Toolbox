import AppKit
import Carbon
import Combine

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

/// One global-shortcut-bearing feature. Every binding is
/// `prefix + (⇧?) + key`: the modifier prefix is a single app-wide setting
/// (General → Keyboard shortcuts); each feature owns only its key, with ⇧
/// allowed as part of the key choice so variants like "same key, shifted =
/// recursive" stay expressible. A new hotkey feature gets a case here, a
/// callback and defaults entry in `HotkeyManager`, and an enable rule in
/// `isActive(_:)` — registration, labels, duplicate checks, and the General
/// overview list all follow from the case.
enum HotkeyFeature: CaseIterable, Hashable {
    case renamePrimary
    case renameSecondary
    case insertDate

    var displayName: String {
        switch self {
        case .renamePrimary:   "Rename selection"
        case .renameSecondary: "Rename (recursive)"
        case .insertDate:      "Insert today's date"
        }
    }

    /// Settings page that owns the feature's key — shown in the overview.
    var settingsPageName: String {
        switch self {
        case .renamePrimary, .renameSecondary: "File Renaming"
        case .insertDate:                      "Insert Date"
        }
    }

    fileprivate var carbonID: UInt32 {
        switch self {
        case .renamePrimary:   1
        case .renameSecondary: 2
        case .insertDate:      3
        }
    }
}

final class HotkeyManager: ObservableObject {
    static let shared = HotkeyManager()

    /// A feature's share of its binding: the key plus an optional ⇧ flavor.
    struct FeatureKey: Equatable, Hashable, Sendable {
        var keyCode: Int
        var shift: Bool
    }

    /// Fired by the primary (non-recursive / "ask") hotkey.
    var onFire: (() -> Void)?
    /// Fired by the secondary (recursive) hotkey, when enabled.
    var onSecondaryFire: (() -> Void)?
    /// Fired by the insert-date hotkey, when enabled.
    var onInsertDateFire: (() -> Void)?

    /// The shared modifier prefix (Carbon flags). Combined with each
    /// feature's `FeatureKey` to form the registered shortcut.
    private(set) var prefixModifiers: UInt32
    private(set) var keys: [HotkeyFeature: FeatureKey]

    /// Master enable for the *rename* hotkeys. When false, neither the
    /// primary nor the secondary hotkey is registered; setup() installs
    /// the Carbon handler anyway so re-enabling is a no-op fast path.
    /// Mirrors `DefaultsKeys.hotkeyEnabled`.
    private(set) var isEnabled: Bool
    /// Secondary hotkey (recursive). Only registered when true (and `isEnabled`).
    private(set) var secondaryEnabled: Bool
    /// Insert-date hotkey. Deliberately *not* gated by `isEnabled` — that
    /// switch is the rename feature's ("Enable rename hotkey" in Settings),
    /// and this belongs to a different tool.
    private(set) var insertDateEnabled: Bool

    private var refs: [HotkeyFeature: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    // ⌃⌥⌘ in Carbon modifier flags
    private static let defaultPrefix = UInt32(controlKey | optionKey | cmdKey)
    private static let defaultKeys: [HotkeyFeature: FeatureKey] = [
        .renamePrimary:   FeatureKey(keyCode: kVK_ANSI_R, shift: false),
        .renameSecondary: FeatureKey(keyCode: kVK_ANSI_R, shift: true),
        .insertDate:      FeatureKey(keyCode: kVK_ANSI_D, shift: false),
    ]

    private init() {
        let d = UserDefaults.standard

        // `hotkeyEnabled` is seeded to true via DefaultsKeys.registerInitialDefaults;
        // bool(forKey:) returns false for that key only on the rare case where
        // initial defaults haven't been registered yet (test harnesses, etc.).
        isEnabled = d.object(forKey: DefaultsKeys.hotkeyEnabled) as? Bool ?? true
        secondaryEnabled = d.bool(forKey: DefaultsKeys.secondaryHotkeyEnabled)
        insertDateEnabled = d.bool(forKey: DefaultsKeys.insertDateHotkeyEnabled)

        // Migration guard: Carbon modifiers are ≤ 8192; old NSEvent rawValues are 100 000+.
        func carbonValid(_ key: String) -> UInt32? {
            guard let raw = d.object(forKey: key) as? Int, raw > 0, raw <= 8192 else { return nil }
            return UInt32(raw)
        }

        let primaryKeyCode = d.object(forKey: DefaultsKeys.hotkeyKeyCode) as? Int
            ?? Self.defaultKeys[.renamePrimary]!.keyCode
        let secondaryKeyCode = d.object(forKey: DefaultsKeys.secondaryHotkeyKeyCode) as? Int
            ?? Self.defaultKeys[.renameSecondary]!.keyCode
        let insertDateKeyCode = d.object(forKey: DefaultsKeys.insertDateHotkeyKeyCode) as? Int
            ?? Self.defaultKeys[.insertDate]!.keyCode

        if let storedPrefix = carbonValid(DefaultsKeys.hotkeyPrefixModifiers) {
            prefixModifiers = storedPrefix
            keys = [
                .renamePrimary:   FeatureKey(keyCode: primaryKeyCode,
                                             shift: d.bool(forKey: DefaultsKeys.hotkeyPrimaryShift)),
                .renameSecondary: FeatureKey(keyCode: secondaryKeyCode,
                                             shift: d.object(forKey: DefaultsKeys.secondaryHotkeyShift) as? Bool ?? true),
                .insertDate:      FeatureKey(keyCode: insertDateKeyCode,
                                             shift: d.bool(forKey: DefaultsKeys.insertDateHotkeyShift)),
            ]
        } else {
            // One-time migration from the pre-prefix model where every feature
            // stored its own full modifier set. The primary hotkey's modifiers
            // (minus ⇧) become the prefix; each feature keeps its key plus
            // whatever ⇧ its old combo carried. Modifier sets that differed
            // from the primary's are deliberately coerced under the prefix —
            // agreed migration policy while the user base is internal testers.
            let shiftMask = UInt32(shiftKey)
            let legacyPrimary = carbonValid(DefaultsKeys.hotkeyModifiers) ?? Self.defaultPrefix
            let legacySecondary = carbonValid(DefaultsKeys.secondaryHotkeyModifiers)
                ?? (Self.defaultPrefix | shiftMask)
            let legacyInsertDate = carbonValid(DefaultsKeys.insertDateHotkeyModifiers) ?? Self.defaultPrefix

            let prefix = legacyPrimary & ~shiftMask
            prefixModifiers = prefix != 0 ? prefix : Self.defaultPrefix
            keys = [
                .renamePrimary:   FeatureKey(keyCode: primaryKeyCode, shift: legacyPrimary & shiftMask != 0),
                .renameSecondary: FeatureKey(keyCode: secondaryKeyCode, shift: legacySecondary & shiftMask != 0),
                .insertDate:      FeatureKey(keyCode: insertDateKeyCode, shift: legacyInsertDate & shiftMask != 0),
            ]
            persist()
        }
    }

    // Call once at app launch.
    func setup() {
        installCarbonHandler()
        if insertDateEnabled { register(.insertDate) }
        guard isEnabled else { return }
        register(.renamePrimary)
        if secondaryEnabled { register(.renameSecondary) }
    }

    /// Whether the feature's shortcut is currently claimed with the system.
    func isActive(_ feature: HotkeyFeature) -> Bool {
        switch feature {
        case .renamePrimary:   isEnabled
        case .renameSecondary: isEnabled && secondaryEnabled
        case .insertDate:      insertDateEnabled
        }
    }

    /// Master enable/disable for the rename hotkeys. When the user toggles
    /// this off in Settings, both are unregistered immediately so the global
    /// shortcuts become free for other apps.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        objectWillChange.send()
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.hotkeyEnabled)
        if enabled {
            register(.renamePrimary)
            if secondaryEnabled { register(.renameSecondary) }
        } else {
            unregister(.renamePrimary)
            unregister(.renameSecondary)
        }
    }

    func setSecondaryEnabled(_ enabled: Bool) {
        guard enabled != secondaryEnabled else { return }
        objectWillChange.send()
        secondaryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.secondaryHotkeyEnabled)
        if enabled && isEnabled { register(.renameSecondary) } else { unregister(.renameSecondary) }
    }

    func setInsertDateEnabled(_ enabled: Bool) {
        guard enabled != insertDateEnabled else { return }
        objectWillChange.send()
        insertDateEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.insertDateHotkeyEnabled)
        if enabled { register(.insertDate) } else { unregister(.insertDate) }
    }

    /// Replace the shared modifier prefix and re-register every active
    /// hotkey. At least one non-⇧ modifier is required — a bare or ⇧-only
    /// prefix would collide with normal typing in every app.
    func setPrefix(carbonModifiers newPrefix: UInt32) {
        guard newPrefix & ~UInt32(shiftKey) != 0, newPrefix != prefixModifiers else { return }
        objectWillChange.send()
        for feature in HotkeyFeature.allCases { unregister(feature) }
        prefixModifiers = newPrefix
        persist()
        for feature in HotkeyFeature.allCases where isActive(feature) { register(feature) }
    }

    /// Change a feature's key. Returns false (and changes nothing) when
    /// another feature already claims the same key+⇧ combination — enabled
    /// or not, since enabling it later would silently collide.
    @discardableResult
    func updateKey(for feature: HotkeyFeature, keyCode: Int, shift: Bool) -> Bool {
        let candidate = FeatureKey(keyCode: keyCode, shift: shift)
        for other in HotkeyFeature.allCases where other != feature {
            if keys[other] == candidate { return false }
        }
        guard keys[feature] != candidate else { return true }
        objectWillChange.send()
        unregister(feature)
        keys[feature] = candidate
        persist()
        if isActive(feature) { register(feature) }
        return true
    }

    func fire(id: UInt32) {
        guard let feature = HotkeyFeature.allCases.first(where: { $0.carbonID == id }) else { return }
        switch feature {
        case .renamePrimary:   onFire?()
        case .renameSecondary: onSecondaryFire?()
        case .insertDate:      onInsertDateFire?()
        }
    }

    // MARK: - Labels

    /// "⌃⌥⌘" — the shared prefix alone.
    var prefixLabel: String {
        Self.modifierSymbols(prefixModifiers)
    }

    /// "⇧R" / "R" — the feature's share of the binding.
    func keyLabel(for feature: HotkeyFeature) -> String {
        let key = keys[feature] ?? Self.defaultKeys[feature]!
        return (key.shift ? "⇧" : "") + Self.keyName(for: key.keyCode)
    }

    /// "⌃⌥⇧⌘R" — the full combo as registered.
    func shortcutLabel(for feature: HotkeyFeature) -> String {
        let key = keys[feature] ?? Self.defaultKeys[feature]!
        return Self.modifierSymbols(effectiveModifiers(for: feature)) + Self.keyName(for: key.keyCode)
    }

    /// Features whose key+⇧ collide with another feature's. Can only occur
    /// via migration of a pre-prefix setup whose combos differed solely by
    /// modifiers; new edits are rejected by `updateKey`. Surfaced as a
    /// warning in the General overview.
    var duplicateKeyFeatures: Set<HotkeyFeature> {
        var seen: [FeatureKey: HotkeyFeature] = [:]
        var duplicates: Set<HotkeyFeature> = []
        for feature in HotkeyFeature.allCases {
            let key = keys[feature] ?? Self.defaultKeys[feature]!
            if let prior = seen[key] {
                duplicates.insert(prior)
                duplicates.insert(feature)
            } else {
                seen[key] = feature
            }
        }
        return duplicates
    }

    // MARK: - Private

    private func effectiveModifiers(for feature: HotkeyFeature) -> UInt32 {
        let key = keys[feature] ?? Self.defaultKeys[feature]!
        return key.shift ? prefixModifiers | UInt32(shiftKey) : prefixModifiers
    }

    private func persist() {
        let d = UserDefaults.standard
        d.set(Int(prefixModifiers), forKey: DefaultsKeys.hotkeyPrefixModifiers)

        let primary = keys[.renamePrimary] ?? Self.defaultKeys[.renamePrimary]!
        let secondary = keys[.renameSecondary] ?? Self.defaultKeys[.renameSecondary]!
        let insertDate = keys[.insertDate] ?? Self.defaultKeys[.insertDate]!
        d.set(primary.keyCode, forKey: DefaultsKeys.hotkeyKeyCode)
        d.set(primary.shift, forKey: DefaultsKeys.hotkeyPrimaryShift)
        d.set(secondary.keyCode, forKey: DefaultsKeys.secondaryHotkeyKeyCode)
        d.set(secondary.shift, forKey: DefaultsKeys.secondaryHotkeyShift)
        d.set(insertDate.keyCode, forKey: DefaultsKeys.insertDateHotkeyKeyCode)
        d.set(insertDate.shift, forKey: DefaultsKeys.insertDateHotkeyShift)

        // Write-through to the legacy full-modifier keys so a downgrade to a
        // pre-prefix beta build still sees the effective combos.
        d.set(Int(effectiveModifiers(for: .renamePrimary)), forKey: DefaultsKeys.hotkeyModifiers)
        d.set(Int(effectiveModifiers(for: .renameSecondary)), forKey: DefaultsKeys.secondaryHotkeyModifiers)
        d.set(Int(effectiveModifiers(for: .insertDate)), forKey: DefaultsKeys.insertDateHotkeyModifiers)
    }

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

    private func register(_ feature: HotkeyFeature) {
        unregister(feature)
        var id = EventHotKeyID()
        id.signature = 0x46545258  // 'FTRX'
        id.id = feature.carbonID
        let key = keys[feature] ?? Self.defaultKeys[feature]!
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(key.keyCode),
            effectiveModifiers(for: feature),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        refs[feature] = ref
    }

    private func unregister(_ feature: HotkeyFeature) {
        guard let ref = refs[feature] else { return }
        UnregisterEventHotKey(ref)
        refs[feature] = nil
    }

    private static func modifierSymbols(_ carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if carbonModifiers & UInt32(optionKey)  != 0 { parts.append("⌥") }
        if carbonModifiers & UInt32(shiftKey)   != 0 { parts.append("⇧") }
        if carbonModifiers & UInt32(cmdKey)     != 0 { parts.append("⌘") }
        return parts.joined()
    }

    static func keyName(for keyCode: Int) -> String {
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
