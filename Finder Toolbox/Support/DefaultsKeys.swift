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

    // Secondary hotkey (recursive rename) — see FolderMode.
    static let secondaryHotkeyEnabled   = "hk.secondaryEnabled"
    static let secondaryHotkeyKeyCode   = "hk.secondaryKeyCode"
    static let secondaryHotkeyModifiers = "hk.secondaryModifiers"

    // Rename
    static let cleanupTrimStem      = "cleanup.trimStemWhitespace"
    static let emlUseDateHeader     = "eml.useDateHeader"

    // Folders. `folderMode` raw values come from `FolderModePreference.rawValue`.
    // `recursiveWarnThreshold` is the file count above which recursive batches require explicit confirmation.
    static let folderMode               = "folders.mode"
    static let recursiveWarnThreshold   = "folders.recursiveWarnThreshold"

    // Updates. `updatesChannel` raw values come from `UpdateChannel.rawValue`;
    // `updatesAutoCheck` / `updatesAutoDownload` mirror Sparkle's
    // `automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates` so the
    // About page can bind to them via `@AppStorage` without poking Sparkle.
    // `updatesLastChecked` is informational only — `SPUUpdater.lastUpdateCheckDate`
    // is the source of truth at runtime; we mirror it here for display.
    static let updatesChannel       = "updates.channel"
    static let updatesAutoCheck     = "updates.autoCheck"
    static let updatesAutoDownload  = "updates.autoDownload"
    static let updatesLastChecked   = "updates.lastChecked"
}
