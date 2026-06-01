import AppKit

// Shows a modal alert only when a batch has failures — clean runs are silent.
enum SummaryDialog {
    /// Above this many lines the alert switches from inline `informativeText`
    /// to a scrollable text view, so a long failure list doesn't stretch the
    /// window off-screen.
    private static let scrollableThreshold = 6
    private static let scrollableWidth: CGFloat = 540
    private static let scrollableHeight: CGFloat = 260

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
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")

        if lines.count <= scrollableThreshold {
            alert.informativeText = lines.joined(separator: "\n")
        } else {
            let failedCount = summary.failed.count
            alert.informativeText = "\(failedCount) item\(failedCount == 1 ? "" : "s") could not be renamed. Details below."
            alert.accessoryView = makeScrollableTextView(content: lines.joined(separator: "\n"))
        }

        alert.runModal()
    }

    /// Shown when a drop-targets move was denied by TCC on the destination
    /// path. Distinct from `showPermissionDenied()` (Automation): the user
    /// has already granted Automation; what's missing is Full Disk Access
    /// (or a per-folder Files & Folders grant) for the AppleScript caller.
    static func showFullDiskAccessRequired() {
        let alert = NSAlert()
        alert.messageText = "Full Disk Access Required"
        alert.informativeText = """
            The destination folder is protected by macOS. Finder Toolbox needs Full Disk Access to move files into it.

            Open System Settings → Privacy & Security → Full Disk Access and enable Finder Toolbox, then try the drop again.

            (In-place renames via the hotkey continue to work without this permission.)
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            PermissionsManager.shared.openSystemSettingsForFullDiskAccess()
        }
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

    // MARK: - Private

    private static func makeScrollableTextView(content: String) -> NSScrollView {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: scrollableWidth, height: scrollableHeight)
        )
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.string = content

        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }
}
