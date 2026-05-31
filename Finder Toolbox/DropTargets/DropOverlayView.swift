import AppKit
import OSLog

/// The drop surface inside a `DropOverlayPanel`. Step-3 minimal version:
/// a colored pill that registers for file URLs + file-promise types, logs
/// `draggingEntered` and `performDragOperation`, and returns the URLs to
/// a callback. Step-4 will wire the callback to the rename pipeline.
final class DropOverlayView: NSView {

    let folderName: String

    /// Called from `performDragOperation` with the resolved file URLs.
    /// Promised files have already been materialized into `tempDir` before
    /// this fires; plain file URLs come through as-is.
    ///
    /// `tempDir` is the destination passed to `NSFilePromiseReceiver`. The
    /// caller owns its lifetime — leave it on disk until the rename
    /// pipeline has moved the files into Finder's target folder.
    var onDrop: ((_ urls: [URL]) -> Void)?

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")
    private let label = NSTextField(labelWithString: "")
    private let promiseQueue = OperationQueue()

    init(folderName: String) {
        self.folderName = folderName
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor

        label.stringValue = "↓ \(folderName)"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
        ])

        // Promise types include file URLs and the file-promise UTIs from
        // NSFilePromiseReceiver.readableDraggedTypes (covers Mail.app,
        // Safari downloads, Photos exports, etc.).
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        registerForDraggedTypes(types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let types = sender.draggingPasteboard.types ?? []
        let sourceMask = sender.draggingSourceOperationMask
        log.info("draggingEntered[\(self.folderName, privacy: .public)] sourceMask=\(sourceMask.rawValue, privacy: .public) types=\(types.map(\.rawValue).joined(separator: ","), privacy: .public)")
        layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.95).cgColor
        // Prefer copy; fall back to whatever the source allows so the drop
        // isn't rejected if the source only offers .move or .generic.
        if sourceMask.contains(.copy) { return .copy }
        if sourceMask.contains(.generic) { return .generic }
        if sourceMask.contains(.move) { return .move }
        if sourceMask.contains(.link) { return .link }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let sourceMask = sender.draggingSourceOperationMask
        if sourceMask.contains(.copy) { return .copy }
        if sourceMask.contains(.generic) { return .generic }
        if sourceMask.contains(.move) { return .move }
        if sourceMask.contains(.link) { return .link }
        return []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        log.debug("draggingExited[\(self.folderName, privacy: .public)]")
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        log.debug("prepareForDragOperation[\(self.folderName, privacy: .public)]")
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor

        let pb = sender.draggingPasteboard
        var resolved: [URL] = []

        // Plain file URLs (Finder drags).
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            resolved.append(contentsOf: urls)
        }

        // Promised files (Mail, Safari, …). The receiver hands back an
        // NSFilePromiseReceiver per item; we ask each to materialize into
        // a temp dir. Step-3 just logs the result.
        let promiseReceivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
        if !promiseReceivers.isEmpty {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("finder-toolbox-drop-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            } catch {
                log.error("dropOverlay: failed to create temp dir: \(error.localizedDescription, privacy: .public)")
            }

            let group = DispatchGroup()
            var promisedURLs: [URL] = []
            let lock = NSLock()
            for receiver in promiseReceivers {
                group.enter()
                receiver.receivePromisedFiles(atDestination: tempDir, options: [:], operationQueue: promiseQueue) { url, error in
                    if let error {
                        self.log.error("dropOverlay: promise receive failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        lock.lock()
                        promisedURLs.append(url)
                        lock.unlock()
                    }
                    group.leave()
                }
            }
            // Wait off the main thread, then dispatch back. The pasteboard
            // server is hung on us returning from performDragOperation, but
            // promise fulfillment runs on the promiseQueue, not main —
            // ok to block briefly. (Step-4 will move this onto a Task and
            // return true synchronously so the source app sees the drop
            // settle immediately.)
            group.wait()
            resolved.append(contentsOf: promisedURLs)
        }

        log.info("dropOverlay[\(self.folderName, privacy: .public)]: drop resolved \(resolved.count, privacy: .public) file(s): \(resolved.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        onDrop?(resolved)
        return !resolved.isEmpty
    }
}
