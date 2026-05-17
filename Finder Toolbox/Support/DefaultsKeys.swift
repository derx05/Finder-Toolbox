import Foundation

/// Central registry of `UserDefaults` keys used across the app.
///
/// Keeping these in one place avoids typos when the same key is read from
/// multiple call sites (e.g. `cleanup.trimStemWhitespace` is both written by
/// `@AppStorage` in Settings and read by `RenameExecutor` off the main thread).
///
/// Marked `nonisolated` so the rename actor (which runs off the main actor)
/// can read these constants without crossing an isolation boundary.
nonisolated enum DefaultsKeys {
    // App
    static let dockMode             = "app.dockMode"
    static let menuBarShowIcon      = "menuBar.showIcon"

    // Hotkey
    static let hotkeyKeyCode        = "hk.keyCode"
    static let hotkeyModifiers      = "hk.modifiers"

    // Rename
    static let cleanupTrimStem      = "cleanup.trimStemWhitespace"
    static let emlUseDateHeader     = "eml.useDateHeader"

    // Updates (placeholder — not wired up yet)
    static let updatesAutoCheck     = "updates.autoCheck"
    static let updatesAutoDownload  = "updates.autoDownload"
    static let updatesLastChecked   = "updates.lastChecked"
}
