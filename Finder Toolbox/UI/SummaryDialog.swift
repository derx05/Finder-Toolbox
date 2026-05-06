import AppKit

// Shows a modal alert only when a batch has failures — clean runs are silent.
enum SummaryDialog {
    static func showIfNeeded(_ summary: BatchSummary) {
        guard summary.hasIssues else { return }

        var lines: [String] = []

        if summary.renamedCount > 0 {
            lines.append("✓ \(summary.renamedCount) file\(summary.renamedCount == 1 ? "" : "s") renamed")
        }

        for (url, error) in summary.failed {
            lines.append("✗ \(url.lastPathComponent): \(error)")
        }

        let alert = NSAlert()
        alert.messageText = "Rename completed with issues"
        alert.informativeText = lines.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Shown when Automation permission for Finder has been denied.
    static func showPermissionDenied() {
        let alert = NSAlert()
        alert.messageText = "Automation Permission Required"
        alert.informativeText = """
            Finder Toolbox needs permission to control Finder in order to rename your selected files.

            Open System Settings → Privacy & Security → Automation and enable Finder for Finder Toolbox.
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsManager.shared.openSystemSettings()
        }
    }
}
