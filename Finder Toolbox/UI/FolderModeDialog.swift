import AppKit

/// Modal dialogs that the recursive-rename workflow uses to confirm intent
/// with the user before touching the filesystem.
enum FolderModeDialog {
    enum Choice {
        case flat
        case recursive
        case cancel
    }

    /// Shown when the Finder selection contains at least one folder and the
    /// user's preference is `.ask`. Lets them pick per-batch instead of
    /// committing to a global setting.
    static func askFolderMode(folderCount: Int, otherCount: Int) -> Choice {
        let alert = NSAlert()
        alert.messageText = folderCount == 1
            ? "Selection contains a folder"
            : "Selection contains \(folderCount) folders"

        var parts: [String] = []
        if otherCount > 0 {
            parts.append("\(otherCount) file\(otherCount == 1 ? "" : "s") will be renamed regardless.")
        }
        parts.append("How should the \(folderCount == 1 ? "folder" : "folders") be handled?")
        alert.informativeText = parts.joined(separator: " ")

        alert.alertStyle = .informational
        // First button is the default (return key) — folder-only is the safer choice.
        alert.addButton(withTitle: "Rename Folder Only")
        alert.addButton(withTitle: "Rename Recursively")
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"  // Escape cancels.

        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .flat
        case .alertSecondButtonReturn: return .recursive
        default:                       return .cancel
        }
    }

    /// Shown before a large recursive batch so the user doesn't accidentally
    /// rename hundreds of files when they meant to rename only the selection.
    static func confirmLargeBatch(fileCount: Int, folderCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Rename \(fileCount) files?"
        var detail = "Recursive rename will affect \(fileCount) file\(fileCount == 1 ? "" : "s")"
        if folderCount > 0 {
            detail += " and \(folderCount) folder\(folderCount == 1 ? "" : "s")"
        }
        detail += ". This action can be undone from the menu bar."
        alert.informativeText = detail
        alert.alertStyle = .warning
        let proceed = alert.addButton(withTitle: "Rename")
        proceed.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }
}
