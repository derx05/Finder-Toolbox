import AppKit
import ApplicationServices
import OSLog

/// Types today's date into whatever text field currently has keyboard
/// focus, in whatever app the user is in.
///
/// ## Why synthetic key events
/// There is no public API to write into another app's text field. The two
/// options are (a) put the text on the pasteboard and synthesize ⌘V, or
/// (b) synthesize key events that carry the characters directly. We use
/// (b): it never touches the user's clipboard, so there's nothing to
/// clobber and nothing to restore on a timer.
///
/// `CGEvent.keyboardSetUnicodeString` attaches a literal string to a key
/// event instead of a keycode, which means the inserted text is
/// independent of the active keyboard layout — no dead-key or
/// non-US-layout surprises.
///
/// ## Permission
/// Posting synthetic events is gated by TCC Accessibility. This is the
/// only capability in the app that needs it (the Carbon hotkey itself
/// does not — see `HotkeyManager`), and it's why the feature ships off by
/// default. `AXIsProcessTrusted()` is a cheap, prompt-free probe; the
/// prompt is only raised when the user explicitly asks for it from
/// Settings.
///
/// ## Modifier release
/// The hotkey fires while its own modifiers (⌃⌥⌘ by default) are still
/// physically held. Apps that read the *global* modifier state — rather
/// than the flags on the event they're handed — would see a modified
/// keystroke and interpret it as a command instead of text. So we clear
/// the flags on the events we post *and* wait briefly for the user to let
/// go of the keys first.
@MainActor
enum DateInserter {

    private static let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "insert-date")

    /// How long to wait for the hotkey's own modifiers to be released
    /// before typing anyway. A normal keypress releases well inside this;
    /// the ceiling exists so a stuck or held-down modifier can't hang the
    /// feature silently.
    private static let modifierReleaseTimeout: TimeInterval = 0.6

    /// `keyboardSetUnicodeString` gets unreliable with long strings, so
    /// the text is posted in chunks. Every supported date format is well
    /// under this; the chunking is here so the helper stays correct if it
    /// is ever reused for longer text.
    private static let maxUnitsPerEvent = 20

    /// The string this feature inserts: today's date in the format
    /// configured under File Renaming → Date format. Deliberately shares
    /// that setting rather than owning a second one — a user who wants
    /// `2026-08-05` in filenames wants it when typing too, and two
    /// pickers that drift apart is a support burden.
    static func todayString() -> String {
        DateFormatStyle.current().format(FilenameBuilder.todayComponents())
    }

    /// Hotkey entry point. Types today's date, or explains why it can't.
    static func insertToday() async {
        guard AXIsProcessTrusted() else {
            log.error("insert-date: Accessibility not granted")
            DebugLog.log("insert-date", "aborted — Accessibility permission not granted", level: .warning)
            NotchFeedbackController.shared.showError(
                "Accessibility permission needed",
                detail: "Finder Toolbox can't type into other apps until it's allowed in System Settings → Privacy & Security → Accessibility."
            )
            return
        }

        let text = todayString()
        await waitForModifierRelease()
        type(text)
        DebugLog.log("insert-date", "typed \"\(text)\"")
    }

    /// Poll the session-wide modifier state until the hotkey's modifiers
    /// are released. Polling (rather than an event monitor) keeps this
    /// self-contained and bounded — it runs only in the few hundred
    /// milliseconds after an explicit keypress, never at idle.
    private static func waitForModifierRelease() async {
        let watched: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        let deadline = Date().addingTimeInterval(modifierReleaseTimeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(watched).isEmpty { return }
            try? await Task.sleep(nanoseconds: 15_000_000) // 15 ms
        }
        log.debug("insert-date: modifiers still held after \(modifierReleaseTimeout)s — typing anyway")
    }

    /// Post the string as a down/up pair per chunk. `virtualKey: 0` is
    /// required: the unicode payload replaces the keycode, and a non-zero
    /// keycode would make some apps act on the key instead of the text.
    /// Flags are cleared so no receiver reads the events as a shortcut.
    private static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("insert-date: could not create CGEventSource")
            return
        }
        for chunk in chunks(of: Array(text.utf16)) {
            var units = chunk
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                log.error("insert-date: could not create key event")
                return
            }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    private static func chunks(of units: [UInt16]) -> [[UInt16]] {
        stride(from: 0, to: units.count, by: maxUnitsPerEvent).map {
            Array(units[$0..<min($0 + maxUnitsPerEvent, units.count)])
        }
    }
}
