import Foundation

/// Registry of every filesystem location Finder Toolbox may read or write
/// outside of the user-selected files it operates on. Surfaced verbatim in
/// the Advanced settings page so users can audit, inspect, or wipe app data
/// without guessing where macOS hides it.
///
/// Keep this list exhaustive. If a new feature introduces a new persistence
/// location, add it here in the same commit.
enum StorageLocationsCatalog {
    enum Kind {
        /// Reveal-in-Finder should select the file inside its parent.
        case file
        /// Reveal-in-Finder should open the directory itself.
        case directory
    }

    struct Entry: Identifiable {
        let id = UUID()
        let displayName: String
        let url: URL
        let purpose: String
        let kind: Kind
        /// `true` when macOS or a third-party framework (Sparkle, the
        /// window-state machinery) owns the path and it may legitimately
        /// not exist yet on a clean install.
        let mayNotExist: Bool
    }

    static var all: [Entry] {
        let bundleID = Bundle.main.bundleIdentifier ?? "danielammann.Finder-Toolbox"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library", isDirectory: true)

        return [
            Entry(
                displayName: "Application bundle",
                url: Bundle.main.bundleURL,
                purpose: "The app itself. Whichever location you installed Finder Toolbox to — typically /Applications.",
                kind: .directory,
                mayNotExist: false
            ),
            Entry(
                displayName: "Preferences",
                url: library
                    .appendingPathComponent("Preferences", isDirectory: true)
                    .appendingPathComponent("\(bundleID).plist"),
                purpose: "All settings stored via UserDefaults: hotkey assignments, date format, folder-rename mode, drop-target configuration, Sparkle update channel and last-checked timestamp.",
                kind: .file,
                mayNotExist: false
            ),
            Entry(
                displayName: "Caches",
                url: library
                    .appendingPathComponent("Caches", isDirectory: true)
                    .appendingPathComponent(bundleID, isDirectory: true),
                purpose: "Drop-target staging directories (subfolder \"drops/\" — promised-file payloads from Mail and SMB shares) and Sparkle's downloaded update archives. Safe to delete when the app is not running.",
                kind: .directory,
                mayNotExist: true
            ),
            Entry(
                displayName: "Application Support",
                url: library
                    .appendingPathComponent("Application Support", isDirectory: true)
                    .appendingPathComponent(bundleID, isDirectory: true),
                purpose: "Reserved for Sparkle's persistent update state. May not exist if no update has been processed yet.",
                kind: .directory,
                mayNotExist: true
            ),
            Entry(
                displayName: "Saved Application State",
                url: library
                    .appendingPathComponent("Saved Application State", isDirectory: true)
                    .appendingPathComponent("\(bundleID).savedState", isDirectory: true),
                purpose: "macOS-managed window-restoration state for the Settings window. Created automatically; not used for any app data.",
                kind: .directory,
                mayNotExist: true
            ),
        ]
    }
}
