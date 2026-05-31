import AppKit
import OSLog

/// Day-one spike for issue #29 (drag-time rename drop targets).
///
/// Validates the three load-bearing assumptions from the issue before any
/// overlay UI is built:
///   1. `NSPasteboard(name: .drag).changeCount` advances at `beginDraggingSession`
///      time on macOS 15.6.
///   2. `.types` is readable from a non-foreground process during an active drag.
///   3. No pasteboard-read banner appears when reading only `.types` (not `.data`).
///
/// Logs to the unified log under subsystem `danielammann.Finder-Toolbox`,
/// category `drag-spike`. Stream with:
///
///     log stream --predicate 'subsystem == "danielammann.Finder-Toolbox" AND category == "drag-spike"' --level debug
///
/// DEBUG-only — wired from `AppController.init` behind `#if DEBUG`. Not
/// user-visible, no settings, no UI side effects. Delete once the spike
/// findings are recorded.
@MainActor
final class DragSessionSpike {
    static let shared = DragSessionSpike()

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drag-spike")
    private let pasteboard = NSPasteboard(name: .drag)

    private enum State { case idle, armed, active }
    private var state: State = .idle
    private var armedChangeCount: Int = 0
    private var monitor: Any?

    /// File-typed pasteboard markers. `.fileURL` covers Finder drags; the
    /// promised-file types cover Mail.app, Safari, and anything using
    /// `NSFilePromiseProvider` — required for the marquee "drag an email
    /// out of Mail onto a Finder window overlay" use case (see spike
    /// findings in issue #29).
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
    ]

    private let snapshot = FinderWindowSnapshot()

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            // Global monitor blocks delivery to other apps if it does work on
            // the main thread synchronously — hop off immediately so we don't
            // measurably affect drag latency in other apps.
            guard let self else { return }
            MainActor.assumeIsolated { self.handle(event) }
        }
        log.info("spike started — drag pasteboard initial changeCount=\(self.pasteboard.changeCount, privacy: .public)")
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            armedChangeCount = pasteboard.changeCount
            state = .armed

        case .leftMouseDragged:
            guard state == .armed else { return }
            let cc = pasteboard.changeCount
            guard cc > armedChangeCount else { return }
            // changeCount advanced since mouseDown → a drag session started.
            let types = pasteboard.types ?? []
            let isFile = !Self.fileTypes.isDisjoint(with: Set(types))
            log.info("""
                drag detected — changeCount \(self.armedChangeCount, privacy: .public)→\(cc, privacy: .public), \
                isFile=\(isFile, privacy: .public), \
                frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)
                """)
            state = .active
            if isFile {
                Task.detached(priority: .userInitiated) { [snapshot, log] in
                    let windows = await snapshot.capture()
                    log.info("snapshot: \(windows.count, privacy: .public) Finder window(s)")
                    for w in windows {
                        log.info("  • id=\(w.windowID, privacy: .public) rect=\(NSStringFromRect(w.screenRect), privacy: .public) folder=\(w.targetFolder.path, privacy: .public) title=\"\(w.title, privacy: .public)\"")
                    }
                }
            }

        case .leftMouseUp:
            if state == .active {
                log.info("drag ended")
            }
            state = .idle

        default:
            break
        }
    }
}
