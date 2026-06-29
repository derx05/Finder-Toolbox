import AppKit
import OSLog

/// Orchestrates the drag-time overlay feature.
///
/// ## Detection and processing pipeline
///
/// ### Phase 1 — Drag detection (DragSessionMonitor, synchronous)
/// A global NSEvent monitor watches leftMouseDown / leftMouseDragged /
/// leftMouseUp for all apps via a three-state machine (idle → armed →
/// active). On leftMouseDown the drag-pasteboard changeCount is
/// snapshotted. On the first leftMouseDragged where changeCount has
/// advanced, the source wrote the pasteboard (beginDraggingSession
/// fired). If the pasteboard has file or promise types, onDragStarted
/// fires. Lag from beginDraggingSession to onDragStarted is one
/// leftMouseDragged tick, typically <16 ms.
///
/// ### Phase 2 — CGWindowList snapshot (handleDragStarted, synchronous, ~2 ms)
/// CGWindowListCopyWindowInfo enumerates all on-screen layer-0 windows
/// and filters to owner == "Finder", giving [(windowID, screenRect)] for
/// every browser window visible on the current Space. For each window:
///   - cache hit  → panel created immediately with the correct label
///   - cache miss → panel created in "loading" state (hourglass)
/// All panels are ordered front before the function returns. Overlays
/// appear within ~5 ms of the drag starting.
///
/// ### Phase 3 — Apple Events folder lookup (async, ~100–300 ms)
/// refreshFolderMap() runs `every Finder window … URL of (target of w)
/// … id of w` via AppleScript on the FinderWindowSnapshot actor (off
/// main thread, serialized). The result updates folderByID and patches
/// any pending / stale panels in place via applyFolderMap.
///
/// Hard constraint: if Finder is the drag source its event loop is
/// occupied by the drag session and it will not answer Apple Events.
/// The AE call returns nil, the cache is preserved, and panels carry
/// whatever was cached before the drag started.
///
/// ### The cache (folderByID)
/// Long-lived map of CGWindowID → (folder URL, window title). Refreshed:
///   - at startup                  one-shot warm for first Finder-source drag
///   - at drag-end                 catches navigation during the drag
///   - at drag-start (re-attempt)  only lands if Finder is not the source
///   - Finder deactivates          user navigated then switched to Mail/etc.
///   - Finder activates            user switched back after navigating elsewhere
/// A nil AE result never overwrites the cache.
///
/// ### Known gap: switch folder → immediately drag from Finder
/// 1. Drag N ends → drag-end refreshFolderMap starts (async AE).
/// 2. User navigates Finder to Folder B (Finder stays frontmost —
///    no activate/deactivate fires, no event we can observe).
/// 3. User starts drag N+1 from Finder before step 1's AE returns.
/// 4. handleDragStarted → cache hit → shows old Folder A label.
/// 5. Drag-start refreshFolderMap → Finder busy as source → nil → no update.
/// 6. Drag N+1 ends → drag-end refresh → Finder answers → cache correct.
/// Result: overlay label during drag N+1 is wrong; the drag AFTER that
/// is correct. The only fix would be kAXTitleChangedNotification on
/// Finder's AXUIElement, which requires Accessibility permissions.
@MainActor
final class DropTargetsCoordinator {
    static let shared = DropTargetsCoordinator()

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")
    private let monitor = DragSessionMonitor()
    private let snapshot = FinderWindowSnapshot()

    private var panels: [DropOverlayPanel] = []

    /// Panels that received a drop and are showing a spinner while the
    /// transfer materializes + lands (issue #40). Held here — and removed
    /// from `panels` — so drag-end teardown leaves them up until the
    /// operation resolves. Keyed by Finder window ID so a second drop on
    /// the same window retires a still-running one rather than stacking.
    private var processingPanels: [CGWindowID: DropOverlayPanel] = [:]

    /// Drag-time context, set on drag-start and cleared on drag-end.
    /// Used to keep every overlay's icon + tint in sync with the
    /// currently-intended operation, even for panels the cursor hasn't
    /// entered yet.
    private var dragSourceURLs: [URL] = []
    private var dragPromiseOnly: Bool = false
    private var modifierMonitorGlobal: Any?
    private var modifierMonitorLocal: Any?

    /// True between drag-start and drag-end.
    private var dragActive: Bool = false

    /// Hover-gating monitors. Re-evaluate panel visibility on every cursor
    /// move while a drag is active.
    private var hoverMonitorGlobal: Any?
    private var hoverMonitorLocal: Any?

    /// Long-lived map of Finder window IDs to (folder, title). Refreshed
    /// at startup, at drag-end, at drag-start (re-attempted; only lands
    /// for non-Finder drag sources — Finder won't answer AE while it's
    /// the drag source), and whenever Finder activates or deactivates
    /// (catches inter-drag navigation without polling).
    ///
    /// The AE script enumerates `every Finder window` regardless of
    /// Space, so a single call covers every Finder browser the user has
    /// open. Space switches mid-drag re-apply this map to the new
    /// visible set without needing a second round-trip.
    ///
    /// A failed AE call (nil from captureFolderMap) does NOT overwrite
    /// this map — the previous entries carry the drag instead.
    private var folderByID: [CGWindowID: (URL, String)] = [:]

    private var folderResolutionTask: Task<Void, Never>?
    private var spaceObserver: NSObjectProtocol?
    private var finderActivateObserver: NSObjectProtocol?
    private var finderDeactivateObserver: NSObjectProtocol?
    private(set) var isRunning = false

    private init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        monitor.onDragStarted = { [weak self] in self?.handleDragStarted() }
        monitor.onDragEnded   = { [weak self] in self?.handleDragEnded() }
        monitor.start()

        // Space-change handler is gated on `dragActive` — outside of a
        // drag the closure is a no-op, so registering once at start()
        // costs nothing while idle.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleSpaceChange()
            }
        }

        // Refresh the folder cache whenever Finder gains or loses focus.
        // Activation: user may have navigated in another Space or background
        // Finder window before switching back. Deactivation: user navigated
        // in Finder then switched to Mail/Photos/etc. to start a drag — by
        // the time the drag fires the cache will be fresh. Both are gated on
        // !dragActive so we don't cancel a useful in-flight drag-start AE.
        let handleFinderSwitch: (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning, !self.dragActive else { return }
                self.refreshFolderMap()
            }
        }
        let wsNC = NSWorkspace.shared.notificationCenter
        finderActivateObserver = wsNC.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier == "com.apple.finder" else { return }
            handleFinderSwitch(note)
        }
        finderDeactivateObserver = wsNC.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier == "com.apple.finder" else { return }
            handleFinderSwitch(note)
        }

        // One-shot warm of the folder cache. The very first drag after
        // launch is otherwise broken when its source is Finder itself
        // (Desktop, iCloud Drive, any Finder window) — Finder won't
        // answer Apple Events during one of its own drags, so we need
        // the cache pre-populated.
        refreshFolderMap()

        log.info("DropTargetsCoordinator started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        monitor.stop()
        monitor.onDragStarted = nil
        monitor.onDragEnded = nil

        let wsNC = NSWorkspace.shared.notificationCenter
        if let spaceObserver { wsNC.removeObserver(spaceObserver) }
        spaceObserver = nil
        if let finderActivateObserver { wsNC.removeObserver(finderActivateObserver) }
        finderActivateObserver = nil
        if let finderDeactivateObserver { wsNC.removeObserver(finderDeactivateObserver) }
        finderDeactivateObserver = nil

        folderResolutionTask?.cancel()
        folderResolutionTask = nil
        folderByID.removeAll()

        hidePanels()
        for panel in processingPanels.values { panel.orderOut(nil) }
        processingPanels.removeAll()

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

        DebugLog.log("drop-targets",
                     "drag started — sources=\(info.urls.count) promiseOnly=\(info.promiseOnly) urls=[\(info.urls.map(\.path).joined(separator: ", "))]")

        // Synchronous: enumerate visible Finder windows from CGWindowList,
        // then pre-populate each panel from the cache. Panels with a
        // cache hit skip the loading state and accept drops immediately;
        // panels without a cache entry (first-ever drag after launch,
        // or a window opened since the last refresh) stay in loading
        // until the fresh AE call below returns.
        let cgWindows = FinderWindowSnapshot.currentVisibleFinderWindows()
        hidePanels()
        var cacheHits = 0
        for entry in cgWindows {
            let panel = makePanel(windowID: entry.id, screenRect: entry.rect)
            if let (folder, title) = folderByID[entry.id] {
                panel.setTarget(folder: folder, title: title)
                cacheHits += 1
            }
            panels.append(panel)
        }
        for panel in panels { panel.orderFrontRegardless() }
        refreshAllPanelOperations()
        startModifierMonitor()
        dragActive = true
        startHoverMonitorIfNeeded()
        applyHoverGating()

        DebugLog.log("drop-targets",
                     "drag started — cgWindows=\(cgWindows.count) panels=\(panels.count) cacheHits=\(cacheHits) hoverGated=\(hoverGatingEnabled)")
        for panel in panels {
            let folderPath = panel.target.targetFolder?.path ?? "<pending>"
            DebugLog.log("drop-targets",
                         "  panel: id=\(panel.target.windowID) rect=\(NSStringFromRect(panel.target.screenRect)) folder=\(folderPath)")
        }

        // Kick a fresh AE round-trip. For fast sources (Mail/Photos —
        // Finder is idle) the answer typically arrives ~200 ms in and
        // updates any stale labels. For Finder-source drags Finder won't
        // respond until drag-end; the cached labels carry the drag, and
        // the drag-end refresh below catches up afterwards.
        refreshFolderMap()
    }

    private func handleDragEnded() {
        DebugLog.log("drop-targets", "drag ended")
        dragActive = false
        stopModifierMonitor()
        stopHoverMonitor()
        hidePanels()
        dragSourceURLs = []
        dragPromiseOnly = false
        // Single AE refresh per drag boundary. Catches any navigation
        // the user did during the drag, plus any windows that were
        // un-queriable while Finder was busy as the drag source.
        refreshFolderMap()
    }

    private func refreshFolderMap() {
        folderResolutionTask?.cancel()
        let snapshot = self.snapshot
        folderResolutionTask = Task { @MainActor [weak self] in
            let map = await snapshot.captureFolderMap()
            guard let self, !Task.isCancelled else { return }
            // nil means AE failed (Finder busy / drag source). Keep the
            // existing cache rather than overwriting with an empty map —
            // a subsequent refresh (drag-end or app-switch) will catch up.
            guard let map else { return }
            self.folderByID = map
            if self.dragActive { self.applyFolderMap(map) }
        }
    }

    /// Re-sync overlay panels to the new Space's visible Finder windows.
    /// CGWindowList can lag the activeSpaceDidChange notification by a
    /// runloop tick, so defer one hop before reading the new visible set.
    /// The resolved folder map from the drag-start AE call covers
    /// windows on every Space, so newly-visible panels can be resolved
    /// from cache without a second AE round-trip.
    private func handleSpaceChange() {
        guard dragActive else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.dragActive else { return }
            self.syncPanelsToCurrentSpace()
        }
    }

    private func syncPanelsToCurrentSpace() {
        let cgWindows = FinderWindowSnapshot.currentVisibleFinderWindows()
        let newIDs = Set(cgWindows.map(\.id))
        let currentIDs = Set(panels.map { $0.target.windowID })
        if newIDs == currentIDs { return }

        // Hide panels for windows no longer visible in this Space.
        var kept: [DropOverlayPanel] = []
        for panel in panels {
            if newIDs.contains(panel.target.windowID) {
                kept.append(panel)
            } else {
                panel.orderOut(nil)
            }
        }
        panels = kept
        let keptIDs = Set(kept.map { $0.target.windowID })

        // Add panels for windows newly brought into view. If the AE
        // resolution has already landed, apply it immediately so the
        // panel skips the loading state entirely.
        for entry in cgWindows where !keptIDs.contains(entry.id) {
            let panel = makePanel(windowID: entry.id, screenRect: entry.rect)
            if let (folder, title) = folderByID[entry.id] {
                panel.setTarget(folder: folder, title: title)
            }
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        refreshAllPanelOperations()
        applyHoverGating()
        DebugLog.log("drop-targets",
                     "space change — synced to \(panels.count) panel(s) for new visible set")
    }

    /// Read the drag pasteboard once at drag-start. Returns the file
    /// URLs (used for source-volume detection) and whether the drag must
    /// always resolve to copy — true for promise-backed sources (Mail
    /// messages, Photos, Safari) and for plain file URLs that live
    /// inside another app's sandbox container (Mail attachments under
    /// `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/`,
    /// any other Containers-rooted source). The latter case needs Full
    /// Disk Access just to read the source, and we never want to
    /// relocate a file out of another app's sandbox.
    private func readDragSourceInfo() -> (urls: [URL], promiseOnly: Bool) {
        let pb = NSPasteboard(name: .drag)
        let types = pb.types ?? []
        let hasLegacyPromise = types.contains { t in
            let raw = t.rawValue
            return raw == "Apple files promise pasteboard type" || raw == "NSPromiseContentsPboardType"
        }
        let promiseSet = Set(NSFilePromiseReceiver.readableDraggedTypes)
        let hasModernPromise = types.contains { promiseSet.contains($0.rawValue) }
        let hasPromise = hasLegacyPromise || hasModernPromise
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let containersPrefix = "\(NSHomeDirectory())/Library/Containers/"
        let inSandboxContainer = urls.contains { $0.standardizedFileURL.path.hasPrefix(containersPrefix) }
        return (urls, hasPromise || inSandboxContainer)
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

    /// Fold the resolved folder map into the live panels. Panels whose
    /// Finder window doesn't appear in the map (info inspectors, "About
    /// Finder", Get Info windows) are dropped — they have no target
    /// folder. Surviving panels refresh their label in place, exit the
    /// loading state, and re-evaluate the move-vs-copy hint with their
    /// now-known volume.
    private func applyFolderMap(_ map: [CGWindowID: (URL, String)]) {
        var surviving: [DropOverlayPanel] = []
        for panel in panels {
            if let (folder, title) = map[panel.target.windowID] {
                panel.setTarget(folder: folder, title: title)
                surviving.append(panel)
            } else if panel.target.targetFolder != nil {
                // Window not in the fresh map but cached data was already
                // applied. Likely a transient AE hiccup — keep the panel
                // and the cached label rather than yanking a target the
                // user can see.
                surviving.append(panel)
            } else {
                panel.orderOut(nil)
            }
        }
        panels = surviving
        refreshAllPanelOperations()
        applyHoverGating()
        DebugLog.log("drop-targets",
                     "folder map resolved — \(surviving.count) panel(s) kept, \(map.count) AE entries")
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

    private func makePanel(windowID: CGWindowID, screenRect: NSRect) -> DropOverlayPanel {
        let window = FinderWindow(
            windowID: windowID,
            screenRect: screenRect,
            targetFolder: nil,
            title: nil
        )
        let panel = DropOverlayPanel(target: window)
        // Drops are refused at the AppKit level until `setTarget` lands
        // (DropOverlayView.draggingEntered/Updated return [] when
        // targetFolder is nil), so by the time this closure fires the
        // panel's `target.targetFolder` is guaranteed non-nil.
        let view = panel.contentView as? DropOverlayView

        // Fired the instant a drop is accepted: detach the panel from the
        // active drag set and switch it into the spinner state so it
        // survives drag-end and shows progress (issue #40).
        view?.onProcessingBegan = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.beginProcessing(panel)
        }

        // Fired when an async materialization yields no files — retire the
        // spinner with a failure flash so it doesn't hang.
        view?.onProcessingFailed = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.finishProcessing(panel, success: false)
        }

        view?.onDrop = { [weak self, weak panel] urls, tempDir, operation in
            guard let panel, let targetFolder = panel.target.targetFolder else {
                if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
                if let self, let panel { self.finishProcessing(panel, success: false) }
                return
            }
            let title = panel.target.title ?? targetFolder.lastPathComponent
            DebugLog.log("drop-targets",
                         "drop accepted on \"\(title)\" — \(urls.count) file(s) op=\(operation) target=\(targetFolder.path) urls=[\(urls.map(\.lastPathComponent).joined(separator: ", "))]")
            Task { @MainActor [weak self, weak panel] in
                let outcome = await AppController.shared.performDrop(urls: urls, into: targetFolder, operation: operation)
                if let tempDir {
                    try? FileManager.default.removeItem(at: tempDir)
                }
                guard let self, let panel else { return }
                switch outcome {
                case .completed(let hadFailures): self.finishProcessing(panel, success: !hadFailures)
                case .failed:                     self.finishProcessing(panel, success: false)
                case .cancelled:                  self.dismissProcessing(panel)
                }
            }
        }
        return panel
    }

    // MARK: - Post-drop processing lifecycle (issue #40)

    /// A drop landed on `panel`: pull it out of the active drag set (so
    /// drag-end teardown won't hide it), re-assert its visibility in case
    /// teardown already ran, and start the spinner. Relies on
    /// `performDragOperation` running before the drag-end mouse-up reaches
    /// our global monitor — the established ordering (see DragSessionMonitor).
    private func beginProcessing(_ panel: DropOverlayPanel) {
        let id = panel.target.windowID
        panels.removeAll { $0 === panel }
        if let existing = processingPanels[id], existing !== panel {
            existing.orderOut(nil)
        }
        processingPanels[id] = panel
        panel.orderFrontRegardless()
        (panel.contentView as? DropOverlayView)?.showProcessing()
        DebugLog.log("drop-targets", "processing started on window \(id)")
    }

    /// Show the brief success / failure confirmation, then schedule the
    /// fade-out. Failures linger a touch longer so they register.
    private func finishProcessing(_ panel: DropOverlayPanel, success: Bool) {
        guard processingPanels[panel.target.windowID] === panel else { return }
        (panel.contentView as? DropOverlayView)?.showResult(success: success)
        let hold: TimeInterval = success ? 0.9 : 1.6
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self, weak panel] in
            guard let panel else { return }
            self?.dismissProcessing(panel)
        }
        DebugLog.log("drop-targets", "processing finished on window \(panel.target.windowID) success=\(success)")
    }

    /// Fade the panel out and stop tracking it. No-op if a newer drop on
    /// the same window has already replaced this panel.
    private func dismissProcessing(_ panel: DropOverlayPanel) {
        let id = panel.target.windowID
        if processingPanels[id] === panel { processingPanels[id] = nil }
        panel.fadeOutAndClose()
    }

    private func hidePanels() {
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
    }
}
