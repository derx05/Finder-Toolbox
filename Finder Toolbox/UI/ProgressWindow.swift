import AppKit

// A small, non-blocking progress panel shown only when a batch takes > 2 seconds.
final class ProgressWindowController {
    private var window: NSPanel?

    func show(fileCount: Int) {
        guard window == nil else { return }

        let label = NSTextField(labelWithString: fileCount > 0
            ? "Renaming \(fileCount) file\(fileCount == 1 ? "" : "s")…"
            : "Renaming…")
        label.font = .systemFont(ofSize: NSFont.systemFontSize)

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)

        // Plain titled panel so the window follows the system appearance
        // (`.hudWindow` forces a dark, monochrome look regardless of light /
        // dark mode).
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 52),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = stack
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.title = "Finder Toolbox"
        panel.appearance = nil  // inherit from system / app
        panel.center()
        panel.orderFront(nil)
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}
