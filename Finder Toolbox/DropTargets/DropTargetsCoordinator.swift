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

    /// Most recent Finder-window snapshot. AppleEvents to Finder cost
    /// ~1–3s on a cold call, far longer than a typical drag, so we can't
    /// fetch on drag-start. Cache is prefetched at startup, refreshed
    /// after each drag ends, and consulted instantly on the next drag.
    private var cachedWindows: [FinderWindow] = []
    private var refreshTask: Task<Void, Never>?

    private init() {}

    func start() {
        monitor.onDragStarted = { [weak self] in self?.handleDragStarted() }
        monitor.onDragEnded   = { [weak self] in self?.handleDragEnded() }
        monitor.start()
        log.info("DropTargetsCoordinator started — warming snapshot cache")
        refreshCache()
    }

    private func handleDragStarted() {
        if cachedWindows.isEmpty {
            log.debug("drag started but snapshot cache empty — first-drag-after-launch race; skipping overlays")
            refreshCache()
            return
        }
        showPanels(for: cachedWindows)
    }

    private func handleDragEnded() {
        hidePanels()
        // User just interacted with Finder; refresh the cache so the next
        // drag sees up-to-date window positions / targets.
        refreshCache()
    }

    private func refreshCache() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            let windows = await self.snapshot.capture()
            if Task.isCancelled { return }
            self.cachedWindows = windows
            self.log.debug("cache refreshed: \(windows.count, privacy: .public) Finder window(s)")
        }
    }

    private func showPanels(for windows: [FinderWindow]) {
        hidePanels()
        guard !windows.isEmpty else {
            log.debug("no qualifying Finder windows — skipping overlays")
            return
        }
        for window in windows {
            let panel = DropOverlayPanel(target: window)
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
