import AppKit
import OSLog

/// Orchestrates the drag-time overlay feature: subscribes to
/// `DragSessionMonitor`, snapshots Finder windows when a file drag
/// begins, shows one overlay panel per qualifying window, and hides
/// everything on drag-end.
///
/// Single instance, main-actor isolated. Step-3 minimum: panels appear
/// and log drops. No settings, no opt-in, no rename wiring yet.
@MainActor
final class DropTargetsCoordinator {
    static let shared = DropTargetsCoordinator()

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")
    private let monitor = DragSessionMonitor()
    private let snapshot = FinderWindowSnapshot()

    private var panels: [DropOverlayPanel] = []

    /// Long-lived map of Finder window IDs to their target folder + name.
    /// AppleEvents to Finder cost ~1–3s on a cold call, but the data is
    /// stable across Space switches (window IDs don't change when you
    /// switch Spaces — only the visible subset does). On every drag-start
    /// we get the current Space's visible windows synchronously from
    /// CGWindowList and join with this cache, giving correct overlays
    /// instantly even right after a Space change.
    ///
    /// Refreshed after each drag ends (catches newly-opened Finder
    /// windows) and at startup.
    private var folderByID: [CGWindowID: (URL, String)] = [:]
    private var refreshTask: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?

    private init() {}

    func start() {
        monitor.onDragStarted = { [weak self] in self?.handleDragStarted() }
        monitor.onDragEnded   = { [weak self] in self?.handleDragEnded() }
        monitor.start()

        // The folder cache survives Space switches (window IDs don't
        // change), but a Space change may bring a previously-unseen
        // Finder window into view — kick off a refresh so its ID maps
        // to a folder by the time the user's next drag-end refresh
        // would have caught it anyway. Cheap and keeps things current.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.log.debug("active Space changed — refreshing folder map")
                self?.refreshFolderMap()
            }
        }

        log.info("DropTargetsCoordinator started — warming folder map")
        refreshFolderMap()
    }

    private func handleDragStarted() {
        // Fast path: synchronous CGWindowList + cached folder map. Works
        // immediately after a Space switch because window IDs are stable.
        let cgWindows = FinderWindowSnapshot.currentVisibleFinderWindows()
        let windows: [FinderWindow] = cgWindows.compactMap { entry in
            guard let (folder, title) = self.folderByID[entry.id] else { return nil }
            return FinderWindow(
                windowID: entry.id,
                screenRect: entry.rect,
                targetFolder: folder,
                title: title
            )
        }
        if windows.isEmpty && !cgWindows.isEmpty {
            log.debug("drag started — \(cgWindows.count, privacy: .public) CG windows but no folder-map matches; first-drag-after-launch? refreshing")
            refreshFolderMap()
            return
        }
        showPanels(for: windows)
    }

    private func handleDragEnded() {
        hidePanels()
        // Catch any Finder windows the user opened during/around the
        // drag so their IDs land in the folder map.
        refreshFolderMap()
    }

    private func refreshFolderMap() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let map = await self.snapshot.captureFolderMap()
            if Task.isCancelled { return }
            self.folderByID = map
            self.log.debug("folder map: \(map.count, privacy: .public) entries")
        }
    }

    private func showPanels(for windows: [FinderWindow]) {
        hidePanels()
        guard !windows.isEmpty else {
            log.debug("no qualifying Finder windows — skipping overlays")
            return
        }
        log.info("showing overlays for windows:")
        for window in windows {
            log.info("  Finder win id=\(window.windowID, privacy: .public) rect=\(NSStringFromRect(window.screenRect), privacy: .public) folder=\(window.targetFolder.path, privacy: .public) title=\"\(window.title, privacy: .public)\"")
        }
        for window in windows {
            let panel = DropOverlayPanel(target: window)
            log.info("  panel for \"\(window.title, privacy: .public)\" placed at \(NSStringFromRect(panel.frame), privacy: .public)")
            (panel.contentView as? DropOverlayView)?.onDrop = { [weak self] urls, tempDir in
                guard let self else { return }
                self.log.info("drop accepted: \(urls.count, privacy: .public) file(s) → \(window.targetFolder.path, privacy: .public)")
                let targetFolder = window.targetFolder
                Task { @MainActor in
                    await AppController.shared.performDrop(urls: urls, into: targetFolder)
                    // Cleanup: the materialize-to-temp dir is now empty
                    // (Finder moved the files out). Best-effort removal —
                    // a leftover directory under /var/folders is harmless
                    // but tidiness is cheap.
                    if let tempDir {
                        try? FileManager.default.removeItem(at: tempDir)
                    }
                }
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        log.info("showed \(self.panels.count, privacy: .public) overlay panel(s)")
    }

    private func hidePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}
