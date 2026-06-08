import AppKit

/// One non-activating HUD-style panel anchored to a single Finder window.
/// Positioned above the title bar so it doesn't overlap the window's
/// content area (which would steal drops the user meant to land in
/// Finder normally — the overlay is an *alternative* target).
@MainActor
final class DropOverlayPanel: NSPanel {

    private(set) var target: FinderWindow

    static let panelSize = NSSize(width: 210, height: 58)
    /// Inset from the Finder window's bottom-right corner. Matches the
    /// window's corner radius so the overlay sits flush against the
    /// inside of the rounded corner without visually clipping it.
    static let cornerInset: CGFloat = 10

    /// Update the panel's target folder + window title after the Apple
    /// Events resolution to Finder returns. The on-screen label refreshes
    /// in place; the panel's frame doesn't move because windowID and
    /// screenRect are known at construction time and don't change.
    func setTarget(folder: URL, title: String) {
        target.targetFolder = folder
        target.title = title
        (contentView as? DropOverlayView)?.setTarget(folderName: folder.lastPathComponent, targetFolder: folder)
    }

    init(target: FinderWindow) {
        self.target = target
        let frame = Self.overlayFrame(for: target)
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        level = .popUpMenu
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        // .transient would dismiss the panel as soon as the source app
        // (Finder, Mail, etc.) regains key during a drop — empirically that
        // tears the panel down before prepareForDragOperation fires, and
        // the drop animates back to source. Use .stationary instead.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false
        // Match the user's current system appearance (Finder follows it
        // too), so the overlay reads as part of the Finder window rather
        // than as an alien HUD.
        appearance = NSApp.effectiveAppearance

        let view = DropOverlayView(
            folderName: target.targetFolder?.lastPathComponent ?? "",
            targetFolder: target.targetFolder
        )
        contentView = view
    }

    /// Compute the on-screen frame for this overlay: anchored to the
    /// inside of the Finder window's bottom-right corner, inset by
    /// `cornerInset` on both edges. Clamped to the screen's visible
    /// frame as a final safety net (for unusually small Finder windows
    /// whose bottom edge is below the dock).
    static func overlayFrame(for target: FinderWindow) -> NSRect {
        let size = panelSize
        let rect = target.screenRect
        var x = rect.maxX - size.width - cornerInset
        var y = rect.minY + cornerInset

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            let visible = screen.visibleFrame
            y = min(max(y, visible.minY), visible.maxY - size.height)
            x = min(max(x, visible.minX), visible.maxX - size.width)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // Borderless panels default to canBecomeKey=false, which blocks the
    // drag-and-drop chain entirely (the panel never receives drag
    // events). Allow key, but combined with `becomesKeyOnlyIfNeeded`
    // and `nonactivatingPanel` the panel stays out of the way of the
    // drag source's focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
