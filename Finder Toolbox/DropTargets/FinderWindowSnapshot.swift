import AppKit
import OSLog

/// One visible Finder window, snapshotted at drag-start.
///
/// `screenRect` is in Cocoa screen coordinates (origin bottom-left, primary
/// screen at y=0). `targetFolder` is the folder that window is showing —
/// the destination an overlay drop would route into.
struct FinderWindow: Sendable, Equatable {
    let windowID: CGWindowID
    let screenRect: NSRect
    let targetFolder: URL
    let title: String
}

/// Enumerates visible Finder windows and joins each one's on-screen rect
/// (from `CGWindowList`) with its target folder (from Apple Events to Finder).
///
/// Designed around the two-speed nature of the data:
/// - `currentVisibleFinderWindows()` is synchronous and fast (~1–2 ms);
///   `CGWindowListCopyWindowInfo` returns the current Space's visible
///   windows immediately. Safe to call on every drag-start.
/// - `captureFolderMap()` is async and slow (~1–3 s cold); it round-trips
///   through Apple Events to Finder for the target folder of every Finder
///   window the user has open. Cache it long-term and refresh after each
///   drag and when a new Finder window may have appeared.
///
/// The folder map is keyed by `kCGWindowNumber`, which equals Finder's
/// AppleScript `id of window` on macOS 15.6 (validated in the day-one
/// spike for issue #29). Window IDs are stable across Space switches —
/// only the set of *visible* windows changes — which is why pairing a
/// fast CG fetch with a long-lived folder cache gives correct results
/// instantly even right after a Space switch.
actor FinderWindowSnapshot {

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")

    struct CGEntry: Sendable {
        let id: CGWindowID
        let rect: NSRect
    }

    /// Synchronous; safe to call from the main actor on the drag-start
    /// hot path. Returns the current Space's visible Finder windows in
    /// front-to-back z-order with their on-screen rects in Cocoa coords.
    nonisolated static func currentVisibleFinderWindows() -> [CGEntry] {
        qualifyingCGWindowsRaw()
    }

    /// Async; pairs each window ID with its target folder POSIX path via
    /// Apple Events to Finder. Cache the result long-term — the join with
    /// fresh CG entries at drag-start handles Space switches correctly.
    func captureFolderMap() async -> [CGWindowID: (URL, String)] {
        do {
            let map = try queryFinderTargets()
            log.info("captureFolderMap: \(map.count, privacy: .public) Finder window(s) cached")
            return map
        } catch {
            log.error("captureFolderMap: Apple Events FAILED: \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    // MARK: - CGWindowList side

    /// Visible Finder windows from `CGWindowListCopyWindowInfo`, in
    /// front-to-back z-order, with desktop and minimized windows filtered
    /// out, and Finder windows whose bottom-right anchor area is covered
    /// by a higher-z window (from any app) skipped — those windows can't
    /// meaningfully host an overlay because the user couldn't see or hit
    /// it. The overlay anchor is the bottom-right region matching
    /// `DropOverlayPanel.panelSize` inset by `DropOverlayPanel.cornerInset`.
    nonisolated private static func qualifyingCGWindowsRaw() -> [CGEntry] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var entries: [CGEntry] = []
        var aboveRects: [NSRect] = []  // rects of windows in front of the current one

        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha == 0 { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }

            // CGWindowList bounds are in CG coords (origin top-left of the
            // primary screen). Convert to Cocoa coords (origin bottom-left)
            // by flipping against the primary screen height.
            let cocoaRect = Self.cocoaFrame(fromCGBounds: bounds)

            let owner = info[kCGWindowOwnerName as String] as? String
            if owner == "Finder", let id = info[kCGWindowNumber as String] as? CGWindowID {
                let anchor = anchorRect(in: cocoaRect)
                let occluded = aboveRects.contains { $0.intersects(anchor) }
                if !occluded {
                    entries.append(CGEntry(id: id, rect: cocoaRect))
                }
            }
            // Every layer-0 window — Finder or otherwise — contributes to
            // occlusion for the windows behind it.
            aboveRects.append(cocoaRect)
        }
        return entries
    }

    /// Mirrors `DropOverlayPanel.overlayFrame(for:)` for the bottom-right
    /// anchor (without the screen clamp — occlusion is a window-space
    /// concern). Kept here rather than importing the panel type so this
    /// stays a leaf utility.
    nonisolated private static func anchorRect(in windowRect: NSRect) -> NSRect {
        let size = NSSize(width: 210, height: 58)
        let inset: CGFloat = 10
        return NSRect(
            x: windowRect.maxX - size.width - inset,
            y: windowRect.minY + inset,
            width: size.width,
            height: size.height
        )
    }

    nonisolated private static func cocoaFrame(fromCGBounds cg: CGRect) -> NSRect {
        guard let primary = NSScreen.screens.first else { return cg }
        let primaryHeight = primary.frame.height
        return NSRect(
            x: cg.origin.x,
            y: primaryHeight - cg.origin.y - cg.size.height,
            width: cg.size.width,
            height: cg.size.height
        )
    }

    // MARK: - Apple Events side

    /// Asks Finder for the (id, target POSIX path, name) of every window.
    /// Returns a dict keyed by window id for joining with the CG list.
    ///
    /// Some Finder windows have no target (e.g. an "About Finder" window,
    /// or a Get Info inspector classed as `information window`). Those are
    /// skipped silently.
    private func queryFinderTargets() throws -> [CGWindowID: (URL, String)] {
        // `Finder windows` is the explicit class for browser windows (the
        // ones with a target folder). Plain `windows` would also include
        // info, clipping, and the desktop window — none of which have a
        // useful POSIX target.
        // Materialize the window list once. `repeat with w in Finder windows`
        // re-resolves `item i of Finder windows` on each iteration and blows
        // up if anything (Spotlight overlay, ⌘-tab transient, our own focus
        // change) mutates the collection mid-loop.
        //
        // `Finder windows` is the explicit class for browser windows (the
        // ones with a target folder). Plain `windows` would also include
        // info, clipping, and the desktop window — none of which have a
        // useful POSIX target.
        let source = """
            tell application "Finder"
                set winList to every Finder window
                set out to {}
                repeat with w in winList
                    try
                        set p to POSIX path of (target of w as alias)
                        set end of out to {id of w, p, name of w}
                    on error errMsg
                        set end of out to {-1, "ERR: " & errMsg, name of w}
                    end try
                end repeat
                {(count of winList), out}
            end tell
        """

        guard let script = NSAppleScript(source: source) else {
            throw FinderBridgeError.scriptFailed("Could not compile script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let info = errorInfo {
            let number = (info["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let message = (info["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error"
            if number == -1743 { throw FinderBridgeError.automationDenied }
            throw FinderBridgeError.scriptFailed(message)
        }

        // Result is {finderWindowCount, [{id, path, name}, ...]}
        let finderCount = result.atIndex(1)?.int32Value ?? -1
        log.info("snapshot AE: Finder windows=\(finderCount, privacy: .public)")

        var out: [CGWindowID: (URL, String)] = [:]
        guard let list = result.atIndex(2) else { return out }
        let count = list.numberOfItems
        guard count > 0 else { return out }
        for i in 1...count {
            guard let entry = list.atIndex(i), entry.numberOfItems == 3 else { continue }
            guard let idDesc = entry.atIndex(1),
                  let pathDesc = entry.atIndex(2),
                  let nameDesc = entry.atIndex(3) else { continue }
            let rawID = idDesc.int32Value
            let path = pathDesc.stringValue ?? ""
            let name = nameDesc.stringValue ?? ""
            log.info("snapshot AE entry: id=\(rawID, privacy: .public) name=\"\(name, privacy: .public)\" path=\"\(path, privacy: .public)\"")
            guard rawID > 0, !path.hasPrefix("ERR:") else { continue }
            out[CGWindowID(rawID)] = (URL(fileURLWithPath: path), name)
        }
        return out
    }
}
