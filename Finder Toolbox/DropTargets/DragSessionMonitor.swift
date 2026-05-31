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

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            armedChangeCount = pasteboard.changeCount
            state = .armed

        case .leftMouseDragged:
            guard state == .armed else { return }
            let cc = pasteboard.changeCount
            guard cc > armedChangeCount else { return }
            let types = pasteboard.types ?? []
            let isFile = !Self.fileTypes.isDisjoint(with: Set(types))
            state = .active
            if isFile {
                log.debug("file drag started — frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?", privacy: .public)")
                onDragStarted?()
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
}
