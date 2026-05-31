import AppKit

/// One non-activating HUD-style panel anchored to a single Finder window.
/// Positioned above the title bar so it doesn't overlap the window's
/// content area (which would steal drops the user meant to land in
/// Finder normally — the overlay is an *alternative* target).
@MainActor
final class DropOverlayPanel: NSPanel {

    let target: FinderWindow

    static let panelSize = NSSize(width: 220, height: 36)
    /// Gap between the Finder window's top edge and the overlay's bottom edge.
    static let topGap: CGFloat = 6

    init(target: FinderWindow) {
        self.target = target
        let frame = Self.overlayFrame(for: target)
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
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

        let view = DropOverlayView(folderName: target.targetFolder.lastPathComponent)
        contentView = view
    }

    /// Compute the on-screen frame for this overlay: centered on the
    /// Finder window's top edge, with a small gap, then clamped hard to
    /// the screen's visible frame so it's never hidden behind the menu
    /// bar (or off the left/right edge for off-center windows).
    ///
    /// Maximized Finder windows have their title bar right at the top
    /// of the screen, which would put the "above title bar" position
    /// behind the menu bar; this routine detects that and tucks the
    /// overlay just inside the top of the window instead.
    static func overlayFrame(for target: FinderWindow) -> NSRect {
        let size = panelSize
        var x = target.screenRect.midX - size.width / 2
        var y = target.screenRect.maxY + topGap

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(target.screenRect) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        if let screen {
            let visible = screen.visibleFrame
            let topLimit = visible.maxY - size.height

            // If "above the title bar" would clip behind the menu bar,
            // tuck below the title bar instead.
            if y > topLimit {
                y = target.screenRect.maxY - size.height - topGap
            }
            // Hard clamp — handles maximized windows whose top edge is
            // itself above visibleFrame, or any other edge case.
            y = min(max(y, visible.minY), topLimit)
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
