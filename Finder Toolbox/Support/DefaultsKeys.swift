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

    // Output date format. Raw values come from `DateFormatStyle.rawValue`;
    // `.system` follows `Locale.current` with `/` sanitized to `-` for
    // filename safety. `datePriority` decides whether a date already in
    // the filename or one extracted from the document wins when both exist.
    static let dateFormatStyle      = "rename.dateFormat"
    static let datePriority         = "rename.datePriority"

    // PDF date extraction. `pdfUseContentDate` is the master toggle; the
    // *Behavior keys hold raw values of `PdfPromptBehavior` / `PdfNoDateBehavior`
    // so every dialog the feature can raise has a "don't ask" setting.
    // `pdfConflictToleranceDays` is the window inside which heuristic and
    // metadata dates are treated as agreeing (no prompt).
    static let pdfUseContentDate         = "pdf.useContentDate"
    static let pdfConflictBehavior       = "pdf.conflictBehavior"
    static let pdfNoDateBehavior         = "pdf.noDateBehavior"
    static let pdfConflictToleranceDays  = "pdf.conflictToleranceDays"
    static let pdfUseOcrFallback         = "pdf.useOcrFallback"

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

    /// Seeds `UserDefaults` with the values the rest of the app reads
    /// directly off `UserDefaults.standard` (notably the rename actor,
    /// which can't go through `@AppStorage`). `@AppStorage` only writes
    /// when the user touches a control, so without this an actor-side
    /// `bool(forKey:)` would return `false` on a fresh install regardless
    /// of what the Settings UI displays as the default.
    nonisolated static func registerInitialDefaults() {
        UserDefaults.standard.register(defaults: [
            emlUseDateHeader:           true,
            dateFormatStyle:            "system", // DateFormatStyle.default
            datePriority:               "content", // DatePriority.default
            pdfUseContentDate:          true,
            pdfConflictBehavior:        "ask",   // PdfConflictBehavior.default
            pdfNoDateBehavior:          "ask",   // PdfNoDateBehavior.default
            pdfConflictToleranceDays:   7,
            pdfUseOcrFallback:          true,
        ])
    }
}
