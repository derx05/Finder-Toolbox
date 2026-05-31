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
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = false

        let view = DropOverlayView(folderName: target.targetFolder.lastPathComponent)
        contentView = view
    }

    /// Compute the on-screen frame for this overlay: centered on the
    /// Finder window's top edge, with a small gap. If the resulting rect
    /// would clip the top of the screen the window lives on, fall back
    /// to attaching below the title bar instead.
    static func overlayFrame(for target: FinderWindow) -> NSRect {
        let size = panelSize
        let x = target.screenRect.midX - size.width / 2
        var y = target.screenRect.maxY + topGap

        // Find the screen this window lives on, clamp upward overflow.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(target.screenRect) }) {
            let topLimit = screen.visibleFrame.maxY - size.height
            if y > topLimit {
                // Drop the overlay just inside the top of the Finder window
                // rather than off-screen.
                y = target.screenRect.maxY - size.height - topGap
            }
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // Required overrides for borderless windows that need to accept
    // drags without becoming key.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
