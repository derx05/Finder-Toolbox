import AppKit
import OSLog

/// Global mouse-event monitor + drag-pasteboard state machine.
///
/// Detects when a *file* drag (real `.fileURL` or promised file from apps
/// like Mail.app / Safari) begins anywhere on the system. The drag
/// pasteboard's `changeCount` advances at `beginDraggingSession` time,
/// which is the trigger — mouse movement without a drag writes nothing,
/// so wiggling, lasso selection, and window dragging don't fire.
///
/// Reading `.types` (not data) avoids the Sonoma+ pasteboard-read banner.
/// Validated end-to-end on macOS 15.6 in the day-one spike (issue #29).
@MainActor
final class DragSessionMonitor {

    /// Fires when a file drag begins. Callback runs on the main actor.
    var onDragStarted: (() -> Void)?
    /// Fires when the drag ends (mouse up after a recognized drag).
    var onDragEnded: (() -> Void)?

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")
    private let pasteboard = NSPasteboard(name: .drag)

    private enum State { case idle, armed, active }
    private var state: State = .idle
    private var armedChangeCount: Int = 0
    /// `pasteboard.changeCount` snapshotted when we entered `.active`.
    /// A later `.leftMouseDragged` with a *different* changeCount means
    /// a fresh drag pasteboard write happened — i.e. a new drag started
    /// without us seeing the intervening `.leftMouseUp` + `.leftMouseDown`.
    private var activeChangeCount: Int = 0
    private var monitor: Any?

    /// File-typed pasteboard markers. `.fileURL` covers Finder drags; the
    /// promised-file types cover Mail.app, Safari, and anything using
    /// `NSFilePromiseProvider`. Without the promise entries, the marquee
    /// "drag an email from Mail onto a Finder window overlay" use case
    /// fails to register (see spike findings in issue #29).
    private static let fileTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type"),
    ]

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return }
            MainActor.assumeIsolated { self.handle(event) }
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        state = .idle
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            // Drag sessions occasionally swallow the trailing .leftMouseUp
            // before it reaches a global event monitor (the drag-back
            // animation after a rejected drop is the usual repro). Without
            // this guard the state machine gets stuck in .active and the
            // next drag's .leftMouseDragged short-circuits at the .armed
            // check — overlays never show. Synthesize the missed end so
            // the new mouseDown starts cleanly.
            if state == .active {
                log.debug("synthesizing drag-ended (missed mouseUp before mouseDown)")
                onDragEnded?()
            }
            armedChangeCount = pasteboard.changeCount
            state = .armed

        case .leftMouseDragged:
            let cc = pasteboard.changeCount
            switch state {
            case .armed:
                guard cc > armedChangeCount else { return }
                let isFile = pasteboardHasFileTypes()
                state = .active
                activeChangeCount = cc
                if isFile {
                    log.debug("file drag started — frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
                    onDragStarted?()
                }
            case .active:
                // Already in a drag from our state machine's perspective.
                // If the drag pasteboard's changeCount has advanced again,
                // a new drag session began without us receiving the
                // intervening `.leftMouseUp` + `.leftMouseDown` (global
                // monitors occasionally drop those — the drag-back
                // animation after a rejected drop is a common repro).
                // Synthesize the missed end + start so the new drag still
                // gets overlays.
                guard cc != activeChangeCount else { return }
                log.debug("drag pasteboard advanced mid-active — synthesizing end + restart")
                onDragEnded?()
                activeChangeCount = cc
                if pasteboardHasFileTypes() {
                    onDragStarted?()
                }
            case .idle:
                // Missed the leading `.leftMouseDown`. Arm with the
                // current changeCount as the baseline; if the drag
                // pasteboard advances on a later dragged event, the next
                // pass through `.armed` will fire. Can't detect the
                // already-in-flight drag (its pasteboard write is in the
                // past) — but at least the NEXT drag will recover cleanly.
                armedChangeCount = cc
                state = .armed
            }

        case .leftMouseUp:
            if state == .active {
                onDragEnded?()
            }
            state = .idle

        default:
            break
        }
    }

    private func pasteboardHasFileTypes() -> Bool {
        let types = pasteboard.types ?? []
        return !Self.fileTypes.isDisjoint(with: Set(types))
    }
}
