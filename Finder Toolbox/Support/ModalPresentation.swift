import AppKit

/// Runs an `NSAlert` modally from a menu-bar-only app.
///
/// `NSAlert.runModal()` spins a nested modal run loop but does not bring an
/// inactive app forward. `LSUIElement` apps are almost never active when a
/// rename dialog needs to appear — the user is in Finder, Mail, or mid-drag.
/// macOS 14 introduced cooperative activation and macOS 26/27 tightened it
/// further, so the alert can end up ordered behind the frontmost app. The
/// app is then stuck in a modal loop with no window the user can see or
/// reach: indistinguishable from a hang.
///
/// Activating first, and pinning the alert above normal windows, keeps the
/// dialog reachable. Use this instead of calling `runModal()` directly.
@MainActor
func runModalActivated(_ alert: NSAlert) -> NSApplication.ModalResponse {
    if !NSApp.isActive {
        NSApp.activate(ignoringOtherApps: true)
    }
    let window = alert.window
    window.level = .modalPanel
    // Drops and hotkeys can fire from any Space; without this the alert
    // would appear on whichever Space the app last had a window on.
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.orderFrontRegardless()
    return alert.runModal()
}
