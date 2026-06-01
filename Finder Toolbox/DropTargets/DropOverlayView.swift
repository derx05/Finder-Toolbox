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

        // Registered drag types:
        // - .fileURL covers plain Finder drags.
        // - NSFilePromiseReceiver.readableDraggedTypes covers modern
        //   NSFilePromiseProvider-based promises (Safari, Photos, …).
        // - The legacy `Apple files promise pasteboard type` is needed
        //   for Mail.app, which only honours the legacy promise contract
        //   even though it writes the modern markers to the pasteboard.
        var types: [NSPasteboard.PasteboardType] = [.fileURL]
        types.append(contentsOf: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        types.append(NSPasteboard.PasteboardType("Apple files promise pasteboard type"))
        types.append(NSPasteboard.PasteboardType("NSPromiseContentsPboardType"))
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
        let types = sender.draggingPasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "<none>"
        log.info("draggingEntered[\(self.folderName, privacy: .public)] mouseAt=\(NSStringFromPoint(mouseInScreen), privacy: .public) panelFrame=\(NSStringFromRect(panelFrame), privacy: .public) sourceMask=\(sourceMask.rawValue, privacy: .public) types=[\(types, privacy: .public)]")
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

        // Mail.app is handled out-of-band: its file-promise contract
        // only fulfills against Finder, so we bypass the promise path
        // entirely and ask Mail (via AppleScript) to write the
        // currently-selected message(s) as .eml. See MailBridge for
        // the full rationale.
        if MailBridge.isMailDrag(pb) {
            return performMailDrop()
        }

        // Check for promises FIRST. Apps like Photos put both
        // `public.file-url` AND a promise on the pasteboard — but the
        // file URL points into the source's managed library bundle
        // (e.g. `.photoslibrary/originals/...`). Reading those URLs and
        // handing them to the rename pipeline would mutate the
        // library's internal storage and corrupt the library. The
        // promise is the source-blessed way to get a *copy* out.
        //
        // Legacy file promises (`Apple files promise pasteboard type` /
        // `NSPromiseContentsPboardType`). Mail.app advertises BOTH the
        // modern (NSFilePromiseProvider) and legacy promise types but
        // only actually fulfills the legacy one — the modern receiver
        // cancels within ~10ms of any drop. So if the pasteboard
        // carries the legacy markers, prefer that path.
        let types = pb.types ?? []
        let hasLegacyPromise = types.contains { t in
            let raw = t.rawValue
            return raw == "Apple files promise pasteboard type" || raw == "NSPromiseContentsPboardType"
        }

        // Modern promises via NSFilePromiseReceiver. Used as a
        // fallback when no legacy promise was offered (Safari,
        // Photos, etc. that DO honour the modern path).
        var promiseReceivers: [NSFilePromiseReceiver] = []
        sender.enumerateDraggingItems(
            options: [],
            for: self,
            classes: [NSFilePromiseReceiver.self],
            searchOptions: [:]
        ) { item, _, _ in
            if let receiver = item.item as? NSFilePromiseReceiver {
                promiseReceivers.append(receiver)
            }
        }

        // No promises at all → safe to consume `public.file-url`s
        // directly (this is the Finder→Finder case where the URL is
        // the actual user-visible file on disk).
        if !hasLegacyPromise && promiseReceivers.isEmpty {
            var fileURLs: [URL] = []
            if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
                fileURLs.append(contentsOf: urls)
            }
            log.info("dropOverlay[\(self.folderName, privacy: .public)]: drop resolved \(fileURLs.count, privacy: .public) file URL(s)")
            if !fileURLs.isEmpty { onDrop?(fileURLs, nil) }
            return !fileURLs.isEmpty
        }

        // Promise present → IGNORE any plain file URLs on the pasteboard.
        // They are the source app's internal originals, not safe to touch.
        let fileURLs: [URL] = []

        // Promise targets land in a staging dir under
        // ~/Library/Caches/<bundle>/drops/. We avoid NSTemporaryDirectory
        // because sandboxed source apps (e.g. Mail's XPC service) can't
        // get a write extension to that path. See `makeStagingDir`.
        guard let dir = makeStagingDir() else { return false }

        if hasLegacyPromise {
            return performLegacyPromiseDrop(sender: sender, dir: dir, fileURLs: fileURLs)
        }
        return performModernPromiseDrop(receivers: promiseReceivers, dir: dir, fileURLs: fileURLs)
    }

    /// Mail.app path: AppleScript-driven, see `MailBridge`. Always
    /// returns `true` synchronously and resolves the actual file(s) on
    /// a background queue so the drag finalize doesn't block on the
    /// AppleEvent round-trip with Mail.
    private func performMailDrop() -> Bool {
        guard let dir = makeStagingDir() else { return false }

        let folderName = self.folderName
        let log = self.log
        let onDrop = self.onDrop

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let urls = try MailBridge.saveSelectedMessages(to: dir)
                DispatchQueue.main.async {
                    log.info("dropOverlay[\(folderName, privacy: .public)]: Mail bridge resolved \(urls.count, privacy: .public) message(s)")
                    if urls.isEmpty {
                        try? FileManager.default.removeItem(at: dir)
                        return
                    }
                    onDrop?(urls, dir)
                }
            } catch {
                log.error("dropOverlay[\(folderName, privacy: .public)]: Mail bridge failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    try? FileManager.default.removeItem(at: dir)
                }
            }
        }
        return true
    }

    /// Creates a unique staging directory under
    /// `~/Library/Caches/<bundle>/drops/`. See the rationale in
    /// `performDragOperation` for why this location is preferred over
    /// `NSTemporaryDirectory()`.
    private func makeStagingDir() -> URL? {
        let cachesRoot = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let bundleID = Bundle.main.bundleIdentifier ?? "danielammann.Finder-Toolbox"
        let dir = cachesRoot
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("drops", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        } catch {
            log.error("dropOverlay: failed to create staging dir: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Legacy promise path: `namesOfPromisedFilesDropped(atDestination:)`
    /// returns the filenames the source app will write into `dir`. The
    /// source then writes them asynchronously (after we return from
    /// performDragOperation) and does NOT signal completion — the
    /// deprecated API has no callback. We poll the directory for the
    /// expected names, with a settle delay so we don't race a partially-
    /// written file. Used by Mail.app.
    private func performLegacyPromiseDrop(sender: NSDraggingInfo, dir: URL, fileURLs: [URL]) -> Bool {
        guard let names = sender.namesOfPromisedFilesDropped(atDestination: dir), !names.isEmpty else {
            log.error("dropOverlay[\(self.folderName, privacy: .public)]: legacy promise but no names returned")
            try? FileManager.default.removeItem(at: dir)
            return false
        }
        log.info("dropOverlay[\(self.folderName, privacy: .public)]: legacy promise expecting \(names.count, privacy: .public) file(s): \(names.joined(separator: ", "), privacy: .public)")

        let expected = names.map { dir.appendingPathComponent($0) }
        let folderName = self.folderName
        let log = self.log
        let onDrop = self.onDrop

        // Poll off main so we don't block the drag finalize. Mail writes
        // .eml files in well under a second on a typical machine.
        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(30)
            var lastSizes: [Int64] = Array(repeating: -1, count: expected.count)
            var stableTicks = 0
            while Date() < deadline {
                let sizes: [Int64] = expected.map { url in
                    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
                }
                let allPresent = sizes.allSatisfy { $0 >= 0 }
                if allPresent && sizes == lastSizes && sizes.allSatisfy({ $0 > 0 }) {
                    stableTicks += 1
                    if stableTicks >= 3 { break } // ~150ms stable
                } else {
                    stableTicks = 0
                }
                lastSizes = sizes
                Thread.sleep(forTimeInterval: 0.05)
            }

            let resolved = expected.filter { FileManager.default.fileExists(atPath: $0.path) }
            DispatchQueue.main.async {
                var all = fileURLs
                all.append(contentsOf: resolved)
                log.info("dropOverlay[\(folderName, privacy: .public)]: legacy promise resolved \(resolved.count, privacy: .public)/\(expected.count, privacy: .public) file(s)")
                if all.isEmpty {
                    try? FileManager.default.removeItem(at: dir)
                    return
                }
                onDrop?(all, dir)
            }
        }
        return true
    }

    /// Modern promise path: NSFilePromiseReceiver fulfills via XPC. Works
    /// for Safari, Photos, Notes, anything using NSFilePromiseProvider.
    /// Mail.app explicitly does NOT fulfill this path even though it
    /// advertises the types — we intercept its drops via the legacy path
    /// above before reaching here.
    private func performModernPromiseDrop(receivers: [NSFilePromiseReceiver], dir: URL, fileURLs: [URL]) -> Bool {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated

        let group = DispatchGroup()
        let urlsBox = PromiseURLBox()
        for receiver in receivers {
            group.enter()
            receiver.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { [log, urlsBox] url, error in
                if let error {
                    log.error("dropOverlay: promise receive failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    urlsBox.append(url)
                }
                group.leave()
            }
        }

        let folderName = self.folderName
        let log = self.log
        let onDrop = self.onDrop
        group.notify(queue: .main) { [urlsBox] in
            var all = fileURLs
            all.append(contentsOf: urlsBox.urls)
            log.info("dropOverlay[\(folderName, privacy: .public)]: modern promise resolved \(all.count, privacy: .public) file(s)")
            if all.isEmpty {
                try? FileManager.default.removeItem(at: dir)
                return
            }
            onDrop?(all, dir)
        }
        return true
    }
}

/// Reference-typed accumulator for promise-fulfillment URLs. The promise
/// completion callbacks fire on a background operation queue; using a
/// class lets all callbacks (and the final notify block on main) share
/// the same storage without value-type copy semantics tripping us up.
private final class PromiseURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        _urls.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return _urls
    }
}

/// Lock-protected bool flag. Used to signal promise-fulfillment
/// completion from a background queue back to the main-thread runloop
/// spin loop.
private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
