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
    /// `tempDir` is non-nil iff at least one promise was materialized.
    /// The receiver is responsible for cleaning it up *after* the rename
    /// pipeline has moved the files out — the temp dir lives under
    /// `NSTemporaryDirectory()` (`/var/folders/.../T/`), not the project
    /// folder, so a missed cleanup leaves an empty dir at most.
    var onDrop: ((_ urls: [URL], _ tempDir: URL?) -> Void)?

    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")
    private let backdrop = NSVisualEffectView()
    private let highlightLayer = CALayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "File Renamer")
    private let folderLabel = NSTextField(labelWithString: "")
    private let promiseQueue = OperationQueue()

    init(folderName: String) {
        self.folderName = folderName
        super.init(frame: .zero)

        wantsLayer = true
        // macOS 26 bumped window corner radii substantially as part of
        // the new design language; 18pt sits close to the visible curve
        // of a Finder browser window's corners. Easy to tweak.
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        // Vibrant popover-style backdrop, adapts to system light/dark.
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)

        // Tint layer for the drag-enter highlight (sits on top of the
        // backdrop, below the labels).
        highlightLayer.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        highlightLayer.opacity = 0
        layer?.addSublayer(highlightLayer)

        let arrow = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        iconView.image = arrow
        iconView.symbolConfiguration = .init(pointSize: 22, weight: .semibold)
        iconView.contentTintColor = .controlAccentColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.wantsLayer = true

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        folderLabel.stringValue = folderName
        folderLabel.font = .systemFont(ofSize: 11, weight: .regular)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.translatesAutoresizingMaskIntoConstraints = false

        // Group the two labels so we can center them as a unit. A bare
        // NSStackView wraps the intrinsic-sized labels tightly, which
        // makes centerY pin them to the true visual center of the panel.
        let textStack = NSStackView(views: [titleLabel, folderLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        // Promise types include file URLs and the file-promise UTIs from
        // NSFilePromiseReceiver.readableDraggedTypes (covers Mail.app,
        // Safari downloads, Photos exports, etc.).
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        registerForDraggedTypes(types)
    }

    override func layout() {
        super.layout()
        highlightLayer.frame = bounds
    }

    override func updateLayer() {
        super.updateLayer()
        // Border color must be refreshed when appearance flips (light/dark).
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    private func setHighlighted(_ on: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        highlightLayer.opacity = on ? 1 : 0
        CATransaction.commit()

        guard let iconLayer = iconView.layer else { return }
        if on {
            // "Conveyor belt" arrow: slides down and fades out, then
            // re-enters from above and slides back to its rest position
            // — visually communicating "files drop in here". Looped
            // while the drag is hovered, halted on exit/drop.
            iconLayer.removeAnimation(forKey: "conveyor-y")
            iconLayer.removeAnimation(forKey: "conveyor-opacity")

            let dropDistance: CGFloat = 12
            let duration: CFTimeInterval = 1.0

            let move = CAKeyframeAnimation(keyPath: "transform.translation.y")
            // Cocoa layer coords are y-up. Down = negative.
            // The middle pair has identical keyTimes so the layer
            // teleports from the bottom to the top — that's the
            // "off-screen reset" that makes the loop feel like a stream.
            move.values   = [0, -dropDistance,  dropDistance, 0]
            move.keyTimes = [0,           0.5,           0.5, 1.0]
            move.duration = duration
            move.repeatCount = .infinity
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            iconLayer.add(move, forKey: "conveyor-y")

            // Fade out near the bottom, stay invisible across the snap,
            // fade back in as the arrow re-enters from the top.
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values   = [1.0, 1.0, 0.0, 0.0, 1.0, 1.0]
            fade.keyTimes = [0.0, 0.3, 0.5, 0.5, 0.7, 1.0]
            fade.duration = duration
            fade.repeatCount = .infinity
            iconLayer.add(fade, forKey: "conveyor-opacity")

            // Gentle background pulse to reinforce the active state
            // without distracting from the arrow loop.
            highlightLayer.removeAnimation(forKey: "pulse")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.55
            pulse.toValue   = 1.0
            pulse.duration  = 1.0
            pulse.autoreverses = true
            pulse.repeatCount  = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            highlightLayer.add(pulse, forKey: "pulse")
        } else {
            iconLayer.removeAnimation(forKey: "conveyor-y")
            iconLayer.removeAnimation(forKey: "conveyor-opacity")
            highlightLayer.removeAnimation(forKey: "pulse")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let sourceMask = sender.draggingSourceOperationMask
        let mouseInScreen = NSEvent.mouseLocation
        let panelFrame = window?.frame ?? .zero
        log.info("draggingEntered[\(self.folderName, privacy: .public)] mouseAt=\(NSStringFromPoint(mouseInScreen), privacy: .public) panelFrame=\(NSStringFromRect(panelFrame), privacy: .public) sourceMask=\(sourceMask.rawValue, privacy: .public)")
        setHighlighted(true)
        // Never accept anything but .copy. Returning .generic or .move
        // from a promise source (Photos, Mail) makes the source treat
        // the destination as the new owner of the file — Photos will
        // move the original asset out of its library bundle, corrupting
        // the library; Mail can do the same to the message store.
        // Better to refuse a drag than to shred someone's data.
        guard sourceMask.contains(.copy) else {
            log.info("dropOverlay[\(self.folderName, privacy: .public)]: source did not offer .copy (mask=\(sourceMask.rawValue, privacy: .public)) — declining drag")
            return []
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        log.debug("draggingExited[\(self.folderName, privacy: .public)]")
        setHighlighted(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        log.debug("prepareForDragOperation[\(self.folderName, privacy: .public)]")
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        setHighlighted(false)

        let pb = sender.draggingPasteboard
        var resolved: [URL] = []
        var tempDir: URL?

        // Probe for file promises FIRST. Apps like Photos put BOTH
        // `public.file-url` AND a file promise on the pasteboard, but
        // the file URL points into the source's managed library bundle
        // (e.g. `.photoslibrary/originals/...`). Reading that URL and
        // handing it to the rename pipeline mutates the library's
        // internal storage and corrupts the library. The promise is the
        // source-blessed way to get a *detached copy* of the asset.
        let promiseReceivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []

        // Plain file URLs are only safe to consume when no promise is
        // on offer (the Finder→Finder case where the URL is the real
        // user-visible file on disk).
        if promiseReceivers.isEmpty {
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                resolved.append(contentsOf: urls)
            }
        }

        // Promised files (Mail, Safari, …). The receiver hands back an
        // NSFilePromiseReceiver per item; each materializes its file
        // into a temp dir on demand. Lives under NSTemporaryDirectory
        // (`/var/folders/.../T/`), not the project — cleanup runs in
        // the coordinator after the rename pipeline moves the files out.
        if !promiseReceivers.isEmpty {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("finder-toolbox-drop-\(UUID().uuidString)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                tempDir = dir
            } catch {
                log.error("dropOverlay: failed to create temp dir: \(error.localizedDescription, privacy: .public)")
            }

            if let dir = tempDir {
                let group = DispatchGroup()
                var promisedURLs: [URL] = []
                let lock = NSLock()
                for receiver in promiseReceivers {
                    group.enter()
                    receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: promiseQueue) { url, error in
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
                // ok to block briefly.
                group.wait()
                resolved.append(contentsOf: promisedURLs)
            }
        }

        log.info("dropOverlay[\(self.folderName, privacy: .public)]: drop resolved \(resolved.count, privacy: .public) file(s): \(resolved.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        onDrop?(resolved, tempDir)
        return !resolved.isEmpty
    }
}
