import AppKit

/// One non-activating HUD-style panel anchored to a single Finder window.
/// Positioned above the title bar so it doesn't overlap the window's
/// content area (which would steal drops the user meant to land in
/// Finder normally — the overlay is an *alternative* target).
@MainActor
final class DropOverlayPanel: NSPanel {

    private(set) var target: FinderWindow

    /// Minimum panel size — also the size used while the target folder is
    /// still being resolved. A drop target narrower than this is awkward
    /// to hit mid-drag, so short folder names don't shrink it.
    static let panelSize = NSSize(width: 210, height: 58)
    /// Upper bound on content-driven growth. Past this the folder label
    /// truncates again; an overlay wider than this stops reading as a
    /// pill and starts covering the window it's anchored to.
    static let maxPanelWidth: CGFloat = 340
    /// Inset from the Finder window's bottom-right corner. Matches the
    /// window's corner radius so the overlay sits flush against the
    /// inside of the rounded corner without visually clipping it.
    static let cornerInset: CGFloat = 10

    /// Update the panel's target folder + window title after the Apple
    /// Events resolution to Finder returns. The on-screen label refreshes
    /// in place, and the panel re-sizes to fit the resolved folder name —
    /// leftward, see `resizeToFit`. The anchor corner is unaffected:
    /// windowID and screenRect are known at construction time and don't
    /// change.
    func setTarget(folder: URL, title: String) {
        target.targetFolder = folder
        target.title = title
        (contentView as? DropOverlayView)?.setTarget(folderName: folder.lastPathComponent, targetFolder: folder)
        resizeToFit(folderName: folder.lastPathComponent)
    }

    init(target: FinderWindow) {
        self.target = target
        let width = Self.preferredWidth(
            folderName: target.targetFolder?.lastPathComponent ?? "",
            in: target.screenRect
        )
        let frame = Self.overlayFrame(for: target, width: width)
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

    /// Width the overlay should have for `folderName`, given the Finder
    /// window it's anchored to. Content-driven, clamped to
    /// `[panelSize.width, maxPanelWidth]` and further capped to the
    /// window's own width so the pill never spills out the left side of
    /// a narrow Finder window. Windows narrower than the minimum keep
    /// the minimum — a sub-210pt drop target isn't worth showing.
    static func preferredWidth(folderName: String, in rect: NSRect) -> CGFloat {
        let available = rect.width - cornerInset * 2
        let upper = max(panelSize.width, min(maxPanelWidth, available))
        let content = DropOverlayView.preferredWidth(folderName: folderName)
        return min(max(content, panelSize.width), upper)
    }

    /// Re-apply the frame for a new label width. The right edge stays
    /// pinned to the Finder window's inside corner, so the panel grows
    /// leftward — growing rightward would push it past the window's edge,
    /// and off-screen entirely for a window flush with the right edge of
    /// the display. Not animated: the panel is a live drop target while
    /// this fires (the Apple Events resolution lands mid-drag), and a
    /// target that slides under the cursor is harder to hit than one that
    /// simply is where it is.
    private func resizeToFit(folderName: String) {
        let width = Self.preferredWidth(folderName: folderName, in: target.screenRect)
        guard abs(width - frame.width) > 0.5 else { return }
        setFrame(Self.overlayFrame(for: target, width: width), display: true)
    }

    /// Compute the on-screen frame for this overlay: anchored to the
    /// inside of the Finder window's bottom-right corner, inset by
    /// `cornerInset` on both edges. Extra width is taken from the left
    /// because the right edge is the anchor. Clamped to the screen's
    /// visible frame as a final safety net (for unusually small Finder
    /// windows whose bottom edge is below the dock).
    static func overlayFrame(for target: FinderWindow, width: CGFloat? = nil) -> NSRect {
        let size = NSSize(width: width ?? panelSize.width, height: panelSize.height)
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

    /// Fade the panel out, then order it off-screen. Used to retire a
    /// processing overlay after its post-drop confirmation (issue #40) so
    /// it doesn't just blink away. Resets `alphaValue` so a recycled panel
    /// object isn't left invisible (panels are recreated per drag, but
    /// this keeps the method self-contained).
    func fadeOutAndClose() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            self?.alphaValue = 1
        })
    }

    // Borderless panels default to canBecomeKey=false, which blocks the
    // drag-and-drop chain entirely (the panel never receives drag
    // events). Allow key, but combined with `becomesKeyOnlyIfNeeded`
    // and `nonactivatingPanel` the panel stays out of the way of the
    // drag source's focus.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
