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

    // Hotkeys use a prefix+key model: `hotkeyPrefixModifiers` is the single
    // app-wide modifier prefix (Carbon flags, set in General settings); each
    // feature stores only its key code plus a ⇧ flag. `hotkeyEnabled` is the
    // master switch for the rename hotkeys: when false, neither primary nor
    // secondary is registered. Users who only want the drag-time drop targets
    // can disable the hotkey for efficiency and to avoid claiming a global
    // shortcut.
    //
    // The legacy per-feature full-modifier keys (`hk.modifiers` etc.) are
    // still *written* with the effective combos so a downgrade to a
    // pre-prefix beta build keeps working; they're only read once, by the
    // migration in `HotkeyManager.init`.
    static let hotkeyPrefixModifiers = "hk.prefixModifiers"
    static let hotkeyEnabled        = "hk.enabled"
    static let hotkeyKeyCode        = "hk.keyCode"
    static let hotkeyPrimaryShift   = "hk.primaryShift"
    static let hotkeyModifiers      = "hk.modifiers"          // legacy write-through

    // Secondary hotkey (recursive rename) — see FolderMode.
    static let secondaryHotkeyEnabled   = "hk.secondaryEnabled"
    static let secondaryHotkeyKeyCode   = "hk.secondaryKeyCode"
    static let secondaryHotkeyShift     = "hk.secondaryShift"
    static let secondaryHotkeyModifiers = "hk.secondaryModifiers"  // legacy write-through

    // Insert-date hotkey — types today's date into whatever text field has
    // focus. Independent of `hotkeyEnabled`: that switch belongs to the
    // rename feature, this one to a different tool. Off by default because
    // it's the only capability that needs an Accessibility grant, and a
    // registered-but-broken global shortcut is worse than none.
    static let insertDateHotkeyEnabled   = "hk.insertDateEnabled"
    static let insertDateHotkeyKeyCode   = "hk.insertDateKeyCode"
    static let insertDateHotkeyShift     = "hk.insertDateShift"
    static let insertDateHotkeyModifiers = "hk.insertDateModifiers"  // legacy write-through

    // Rename
    static let cleanupTrimStem      = "cleanup.trimStemWhitespace"
    static let emlUseDateHeader     = "eml.useDateHeader"

    // Output date format. Raw values come from `DateFormatStyle.rawValue`;
    // `.system` follows `Locale.current` with `/` sanitized to `-` for
    // filename safety. `datePriority` decides whether a date already in
    // the filename or one extracted from the document wins when both exist.
    static let dateFormatStyle      = "rename.dateFormat"
    static let datePriority         = "rename.datePriority"
    // Disambiguates numeric dates whose field order can't be inferred from the
    // string itself (e.g. "12-05-2012"). Raw values come from
    // `DateAmbiguityOrder.rawValue`. Defaults to day-first.
    static let dateAmbiguityOrder   = "rename.dateAmbiguityOrder"

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
    // `folderRenameScope` raw values come from `FolderRenameScopePreference.rawValue`.
    // Decides whether folder *names* themselves are eligible for renaming
    // when folders are involved (either in the selection or reached via
    // recursive descent). Orthogonal to `folderMode`: scope decides whether
    // folders are renamed, mode decides whether we descend into them.
    // Defaults to files-only — folders normally don't carry a meaningful date.
    static let folderRenameScope        = "folders.renameScope"
    // When false, recursive batches skip the size-threshold confirmation
    // dialog entirely. Risky — exists so power users who know what they're
    // doing can avoid the prompt without setting an absurdly high threshold.
    static let recursiveWarnEnabled     = "folders.recursiveWarnEnabled"
    static let recursiveWarnThreshold   = "folders.recursiveWarnThreshold"

    // Drag-time drop targets (issue #29). Off by default — opt-in via Settings.
    static let dropTargetsEnabled       = "dropTargets.enabled"
    // Hover gating: only show a window's overlay while the cursor is over
    // that Finder window (and the window isn't occluded at the cursor).
    // Cuts visual noise when many Finder windows are open.
    static let dropTargetsHoverGated    = "dropTargets.hoverGated"

    // Developer / debugging. `dropTargetsDebugLog` enables the in-app ring
    // buffer in `DebugLog`; OSLog mirroring happens unconditionally.
    // `showDropDebugPopups` shows an auto-dismissing toast after each drop
    // with the drop's resolved details and the executor summary.
    static let dropTargetsDebugLog      = "debug.dropTargetsLog"
    static let showDropDebugPopups      = "debug.showDropPopups"

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
            hotkeyEnabled:              true,
            insertDateHotkeyEnabled:    false,
            emlUseDateHeader:           true,
            dateFormatStyle:            "system", // DateFormatStyle.default
            datePriority:               "content", // DatePriority.default
            dateAmbiguityOrder:         "dayFirst", // DateAmbiguityOrder.default
            recursiveWarnEnabled:       true,
            folderRenameScope:          "filesOnly", // FolderRenameScopePreference.default
            pdfUseContentDate:          true,
            pdfConflictBehavior:        "ask",   // PdfConflictBehavior.default
            pdfNoDateBehavior:          "ask",   // PdfNoDateBehavior.default
            pdfConflictToleranceDays:   7,
            pdfUseOcrFallback:          true,
        ])
    }
}
