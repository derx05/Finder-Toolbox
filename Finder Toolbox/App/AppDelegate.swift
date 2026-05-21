import AppKit
import SwiftUI

/// AppKit lifecycle bridge.
///
/// SwiftUI doesn't expose hooks for "user re-activated the running app"
/// (Cmd-Tab, Dock click, Spotlight launch while running). This delegate
/// fills that gap and routes the user to Settings, which is the only
/// window the app has outside of the rename progress panel.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug builds launched from Xcode while a release copy is already
        // running would otherwise compete for the global hotkey. Terminate
        // any sibling instances first.
        if BuildConfiguration.isDebug {
            terminateOtherInstances()
        }

        // Force-instantiate so DockModeManager applies the persisted
        // activation policy (.regular vs .accessory) before any window appears.
        _ = DockModeManager.shared

        // Start Sparkle. Deferred until didFinishLaunching so the persisted
        // update channel + auto-check prefs are mirrored into the updater
        // before its first scheduled check fires.
        UpdateController.shared.start()
    }

    private func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        for app in others {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
    }

    /// Keep the app alive when the user closes Settings — the hotkey is the
    /// primary surface, the window is incidental.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// In non-`normal` dock modes a Cmd-Q only closes visible windows so the
    /// menu bar surface stays alive. The "Quit" buttons set `isExplicitQuit`
    /// to bypass this guard.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = DockModeManager.shared
        if manager.mode == .normal || manager.isExplicitQuit {
            return .terminateNow
        }
        sender.windows.filter(\.isVisible).forEach { $0.close() }
        return .terminateCancel
    }

    /// Dock-icon click or Spotlight relaunch while already running → open Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    /// Cmd-Tab back into the app. Only open Settings if nothing is already
    /// on-screen — otherwise we'd interrupt an in-progress session.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !NSApp.windows.contains(where: { $0.isVisible }) else { return }
        openSettings()
    }

    private func openSettings() {
        MainActor.assumeIsolated {
            DockModeManager.shared.willOpenSettings()
            NSApp.activate(ignoringOtherApps: true)
            AppController.shared.openSettingsAction?()
        }
    }
}
