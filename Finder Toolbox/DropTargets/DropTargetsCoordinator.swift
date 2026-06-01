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

    /// Drag-time context, set on drag-start and cleared on drag-end.
    /// Used to keep every overlay's icon + tint in sync with the
    /// currently-intended operation, even for panels the cursor hasn't
    /// entered yet.
    private var dragSourceURLs: [URL] = []
    private var dragPromiseOnly: Bool = false
    private var modifierMonitorGlobal: Any?
    private var modifierMonitorLocal: Any?

    /// True between drag-start and drag-end. Drives the Space-change
    /// rebuild and the hover-gating monitor; both are no-ops outside a drag.
    private var dragActive: Bool = false

    /// Hover-gating monitors. Re-evaluate panel visibility on every cursor
    /// move while a drag is active.
    private var hoverMonitorGlobal: Any?
    private var hoverMonitorLocal: Any?

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
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

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
                guard let self else { return }
                self.log.debug("active Space changed — refreshing folder map")
                self.refreshFolderMap()
                if self.dragActive { self.rebuildPanelsForCurrentSpace() }
            }
        }

        log.info("DropTargetsCoordinator started — warming folder map")
        refreshFolderMap()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        monitor.stop()
        monitor.onDragStarted = nil
        monitor.onDragEnded = nil

        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        spaceObserver = nil

        refreshTask?.cancel()
        refreshTask = nil

        hidePanels()
        folderByID.removeAll()

        log.info("DropTargetsCoordinator stopped")
    }

    /// Reads `DefaultsKeys.dropTargetsEnabled` and starts/stops the
    /// coordinator accordingly. Safe to call repeatedly — start/stop
    /// are no-ops when already in the desired state.
    func refreshFromDefaults() {
        let enabled = UserDefaults.standard.bool(forKey: DefaultsKeys.dropTargetsEnabled)
        if enabled { start() } else { stop() }
    }

    private func handleDragStarted() {
        // Snapshot the drag pasteboard once at drag-start so every panel
        // can be primed with the right operation immediately — and so
        // we don't re-read on every modifier-key tick.
        let info = readDragSourceInfo()
        dragSourceURLs = info.urls
        dragPromiseOnly = info.promiseOnly

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
        refreshAllPanelOperations()
        startModifierMonitor()
        dragActive = true
        startHoverMonitorIfNeeded()
        applyHoverGating()
    }

    private func handleDragEnded() {
        dragActive = false
        stopModifierMonitor()
        stopHoverMonitor()
        hidePanels()
        dragSourceURLs = []
        dragPromiseOnly = false
        // Catch any Finder windows the user opened during/around the
        // drag so their IDs land in the folder map.
        refreshFolderMap()
    }

    /// Read the drag pasteboard once at drag-start. Returns the file
    /// URLs (used for source-volume detection) and whether the drag is
    /// promise-only (Mail / Photos / Safari — must always copy).
    private func readDragSourceInfo() -> (urls: [URL], promiseOnly: Bool) {
        let pb = NSPasteboard(name: .drag)
        let types = pb.types ?? []
        let hasLegacyPromise = types.contains { t in
            let raw = t.rawValue
            return raw == "Apple files promise pasteboard type" || raw == "NSPromiseContentsPboardType"
        }
        let promiseSet = Set(NSFilePromiseReceiver.readableDraggedTypes)
        let hasModernPromise = types.contains { promiseSet.contains($0.rawValue) }
        let promiseOnly = hasLegacyPromise || hasModernPromise
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return (urls, promiseOnly)
    }

    /// Re-evaluate the current operation for every visible overlay.
    /// Each panel's target folder volume + the held modifiers may
    /// produce a different answer per window — Desktop → NAS is copy
    /// while Desktop → Desktop is move, for example.
    private func refreshAllPanelOperations() {
        for panel in panels {
            guard let view = panel.contentView as? DropOverlayView else { continue }
            view.reflectOperation(sourceURLs: dragSourceURLs, promiseOnly: dragPromiseOnly)
        }
    }

    /// While a drag is active, watch for modifier-flag changes (⌥, ⌘)
    /// and re-tint every panel. Global monitor catches the usual case
    /// (Finder is frontmost during the drag); local monitor covers the
    /// rare case where our own app is frontmost.
    private func startModifierMonitor() {
        if modifierMonitorGlobal == nil {
            modifierMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAllPanelOperations() }
            }
        }
        if modifierMonitorLocal == nil {
            modifierMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                MainActor.assumeIsolated { self?.refreshAllPanelOperations() }
                return event
            }
        }
    }

    private func stopModifierMonitor() {
        if let modifierMonitorGlobal { NSEvent.removeMonitor(modifierMonitorGlobal) }
        if let modifierMonitorLocal { NSEvent.removeMonitor(modifierMonitorLocal) }
        modifierMonitorGlobal = nil
        modifierMonitorLocal = nil
    }

    /// Re-snapshot the current Space's Finder windows and rebuild overlay
    /// panels mid-drag. Deferred one runloop tick because
    /// `activeSpaceDidChangeNotification` can fire fractionally before
    /// `CGWindowListCopyWindowInfo` reports the new Space's visible set.
    private func rebuildPanelsForCurrentSpace() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dragActive else { return }
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
            self.log.debug("Space change mid-drag — rebuilding \(windows.count, privacy: .public) panel(s)")
            self.showPanels(for: windows)
            self.refreshAllPanelOperations()
            self.applyHoverGating()
        }
    }

    // MARK: - Hover gating

    private var hoverGatingEnabled: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKeys.dropTargetsHoverGated)
    }

    private func startHoverMonitorIfNeeded() {
        guard hoverGatingEnabled, hoverMonitorGlobal == nil else { return }
        // `.leftMouseDragged` is what we get during a drag — `.mouseMoved`
        // is suppressed by the system while a drag is in flight. Frequency
        // is ~60 Hz; refreshing per panel visibility is cheap.
        hoverMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHoverGating() }
        }
        hoverMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated { self?.applyHoverGating() }
            return event
        }
    }

    private func stopHoverMonitor() {
        if let hoverMonitorGlobal { NSEvent.removeMonitor(hoverMonitorGlobal) }
        if let hoverMonitorLocal { NSEvent.removeMonitor(hoverMonitorLocal) }
        hoverMonitorGlobal = nil
        hoverMonitorLocal = nil
    }

    /// When hover-gating is off, every panel should be visible (default
    /// behavior). When on, a panel is visible only if the cursor lies
    /// inside its Finder window AND the topmost non-overlay window at the
    /// cursor is that same Finder window (i.e. nothing's covering it).
    private func applyHoverGating() {
        guard hoverGatingEnabled else {
            for panel in panels where !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        let cursor = NSEvent.mouseLocation
        let ownIDs = Set(panels.map { CGWindowID($0.windowNumber) })
        let top = FinderWindowSnapshot.topmostWindow(at: cursor, excluding: ownIDs)
        for panel in panels {
            let insideWindow = panel.target.screenRect.contains(cursor)
            let isTopFinder = (top?.owner == "Finder") && (top?.id == panel.target.windowID)
            let shouldShow = insideWindow && isTopFinder
            if shouldShow {
                if !panel.isVisible { panel.orderFrontRegardless() }
            } else {
                if panel.isVisible { panel.orderOut(nil) }
            }
        }
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
            (panel.contentView as? DropOverlayView)?.onDrop = { [weak self] urls, tempDir, operation in
                guard let self else { return }
                self.log.info("drop accepted: \(urls.count, privacy: .public) file(s) → \(window.targetFolder.path, privacy: .public) op=\(String(describing: operation), privacy: .public)")
                let targetFolder = window.targetFolder
                Task { @MainActor in
                    await AppController.shared.performDrop(urls: urls, into: targetFolder, operation: operation)
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
