import XCTest
import AppKit
@testable import Finder_Toolbox

/// Geometry rules for the drag-time drop overlay. The load-bearing one is
/// that the panel's right edge is the anchor: extra width for a long
/// folder name has to come off the left, because growing rightward pushes
/// the overlay out of its Finder window — and off-screen entirely for a
/// window flush with the right edge of the display.
@MainActor
final class DropOverlayPanelTests: XCTestCase {

    /// A Finder-window rect comfortably inside the main screen's visible
    /// frame, so `overlayFrame`'s screen clamp never engages and the tests
    /// observe the anchoring rule alone.
    private func unclampedWindowRect(width: CGFloat = 900) -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.minX + 100,
            y: visible.minY + 100,
            width: min(width, visible.width - 200),
            height: min(600, visible.height - 200)
        )
    }

    private func window(rect: NSRect) -> FinderWindow {
        FinderWindow(windowID: 1, screenRect: rect, targetFolder: nil, title: nil)
    }

    // MARK: - Width

    func testShortFolderNameKeepsMinimumWidth() {
        let rect = unclampedWindowRect()
        let width = DropOverlayPanel.preferredWidth(folderName: "Docs", in: rect)
        XCTAssertEqual(width, DropOverlayPanel.panelSize.width)
    }

    func testEmptyFolderNameKeepsMinimumWidth() {
        let rect = unclampedWindowRect()
        let width = DropOverlayPanel.preferredWidth(folderName: "", in: rect)
        XCTAssertEqual(width, DropOverlayPanel.panelSize.width)
    }

    func testLongFolderNameGrowsBeyondMinimum() {
        let rect = unclampedWindowRect()
        let width = DropOverlayPanel.preferredWidth(
            folderName: "Rechnungen und Belege 2026 Quartal 3 Archiv",
            in: rect
        )
        XCTAssertGreaterThan(width, DropOverlayPanel.panelSize.width)
    }

    func testWidthIsCappedAtMaximum() {
        let rect = unclampedWindowRect()
        let width = DropOverlayPanel.preferredWidth(
            folderName: String(repeating: "Sehr langer Ordnername ", count: 20),
            in: rect
        )
        XCTAssertEqual(width, DropOverlayPanel.maxPanelWidth)
    }

    func testWidthNeverExceedsTheFinderWindow() {
        // 260pt window: the content wants more, the cap is the window.
        let rect = unclampedWindowRect(width: 260)
        let width = DropOverlayPanel.preferredWidth(
            folderName: String(repeating: "Langer Ordnername ", count: 10),
            in: rect
        )
        XCTAssertLessThanOrEqual(width, rect.width - DropOverlayPanel.cornerInset * 2)
    }

    func testWindowNarrowerThanMinimumStillGetsMinimumWidth() {
        // Below the minimum the overlay would be unusable as a drop
        // target, so the minimum wins over the window cap.
        let rect = NSRect(x: 200, y: 200, width: 150, height: 300)
        let width = DropOverlayPanel.preferredWidth(folderName: "A", in: rect)
        XCTAssertEqual(width, DropOverlayPanel.panelSize.width)
    }

    // MARK: - Anchoring

    func testGrowthGoesLeftwardWithTheRightEdgePinned() {
        let rect = unclampedWindowRect()
        let target = window(rect: rect)

        let narrow = DropOverlayPanel.overlayFrame(for: target, width: 210)
        let wide   = DropOverlayPanel.overlayFrame(for: target, width: 340)

        XCTAssertEqual(narrow.maxX, wide.maxX, accuracy: 0.001,
                       "The right edge is the anchor — it must not move when the panel widens")
        XCTAssertLessThan(wide.minX, narrow.minX,
                          "Extra width has to come off the left edge")
    }

    func testRightEdgeSitsInsideTheFinderWindow() {
        let rect = unclampedWindowRect()
        let target = window(rect: rect)
        let frame = DropOverlayPanel.overlayFrame(for: target, width: 340)

        XCTAssertEqual(frame.maxX, rect.maxX - DropOverlayPanel.cornerInset, accuracy: 0.001)
        XCTAssertLessThanOrEqual(frame.maxX, rect.maxX)
    }

    func testWidestPanelStaysWithinAWindowThatCanHoldIt() {
        let rect = unclampedWindowRect()
        let target = window(rect: rect)
        let width = DropOverlayPanel.preferredWidth(
            folderName: String(repeating: "Ordner ", count: 30),
            in: rect
        )
        let frame = DropOverlayPanel.overlayFrame(for: target, width: width)

        XCTAssertGreaterThanOrEqual(frame.minX, rect.minX,
                                    "A window wide enough for the panel must fully contain it")
        XCTAssertLessThanOrEqual(frame.maxX, rect.maxX)
    }

    func testFrameIsClampedToTheVisibleScreen() {
        // A window hanging off the right edge of its display: the panel
        // would follow it off-screen without the clamp. Which display
        // that is depends on the machine's arrangement, so resolve it the
        // same way `overlayFrame` does rather than assuming the main one.
        guard let main = NSScreen.main else { return }
        let rect = NSRect(x: main.visibleFrame.maxX - 200,
                          y: main.visibleFrame.minY + 100,
                          width: 900, height: 500)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = DropOverlayPanel.overlayFrame(for: window(rect: rect), width: 340)

        XCTAssertLessThanOrEqual(frame.maxX, visible.maxX + 0.001)
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX - 0.001)
    }

    func testDefaultWidthMatchesTheMinimum() {
        let target = window(rect: unclampedWindowRect())
        XCTAssertEqual(
            DropOverlayPanel.overlayFrame(for: target).width,
            DropOverlayPanel.panelSize.width
        )
    }
}
