import Foundation
import OSLog

enum FinderBridgeError: LocalizedError {
    case noSelection
    case scriptFailed(String)
    case automationDenied
    /// Finder reported a TCC denial on the destination of a move. Distinct
    /// from `.automationDenied`: Automation is granted, but the AppleScript
    /// caller (us) lacks Full Disk Access (or a per-folder Files & Folders
    /// grant) for the move target.
    case destinationNotPermitted

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "No files are selected in Finder."
        case .scriptFailed(let msg):
            "AppleScript error: \(msg)"
        case .automationDenied:
            "Automation access to Finder has not been granted. Open System Settings → Privacy & Security → Automation to enable it."
        case .destinationNotPermitted:
            "The destination folder requires Full Disk Access. Open System Settings → Privacy & Security → Full Disk Access and enable Finder Toolbox."
        }
    }
}

// All methods run synchronous NSAppleScript calls — must be called off the main thread.
actor FinderBridge {

    nonisolated private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "finder-bridge")

    func selectedFileURLs() throws -> [URL] {
        let source = """
            tell application "Finder"
                set sel to selection as alias list
                set paths to {}
                repeat with f in sel
                    set end of paths to POSIX path of f
                end repeat
                paths
            end tell
        """
        let result = try runScript(source)

        var urls: [URL] = []
        let count = result.numberOfItems
        if count > 0 {
            for i in 1...count {
                if let path = result.atIndex(i)?.stringValue {
                    urls.append(URL(fileURLWithPath: path))
                }
            }
        }

        if urls.isEmpty { throw FinderBridgeError.noSelection }
        return urls
    }

    // Renames all files in a single tell block so Finder groups them as one undo action.
    // Returns per-file results; failures don't abort remaining renames (falls back to
    // individual scripts when the batch script fails).
    func batchRename(_ renames: [(from: URL, to: String)]) -> [RenameOutcome] {
        guard !renames.isEmpty else { return [] }

        // Attempt single-block batch for undo grouping.
        if let outcomes = tryBatchScript(renames) {
            return outcomes
        }

        // The batch halted partway through. AppleScript's default error
        // behavior is to abort the whole `tell` block on the first failure,
        // so a chunk of earlier commands may already have succeeded in
        // Finder. Probe the filesystem before retrying any item — otherwise
        // we'd re-issue successful renames and Finder would respond with
        // "Can't set item X" because X no longer exists under its old name.
        return renames.map { rename in
            let toURL = rename.from.deletingLastPathComponent().appendingPathComponent(rename.to)
            let fm = FileManager.default
            let originalExists = fm.fileExists(atPath: rename.from.path)
            let targetExists = fm.fileExists(atPath: toURL.path)

            if !originalExists && targetExists {
                // The batch already renamed this one; report it as renamed
                // rather than retrying.
                return .renamed(from: rename.from, to: toURL)
            }

            do {
                try renameSingle(from: rename.from, to: rename.to)
                return .renamed(from: rename.from, to: toURL)
            } catch {
                return .failed(rename.from, error: error.localizedDescription)
            }
        }
    }

    /// Moves each item into its target folder and renames it in a single
    /// Finder transaction, so the whole batch is one entry in Finder's
    /// native undo stack. Source and target may be on different volumes —
    /// Finder handles cross-volume moves as a copy + delete.
    ///
    /// Caller is responsible for ensuring `newName` is already unique in
    /// `targetFolder` (do conflict resolution upstream). `move … to …`
    /// without `with replacing` will fail if a same-named file exists.
    func moveAndRename(_ items: [(source: URL, targetFolder: URL, newName: String)]) -> [RenameOutcome] {
        guard !items.isEmpty else { return [] }

        // Network volumes (SMB/AFP) are split off: Finder's `move … to
        // folder …` AppleScript verb is unreliable against them and
        // commonly fails with "operation can't be completed". For those,
        // do the move via FileManager and use Finder only for the
        // visible rename, which is the part the user notices in undo.
        var local: [(source: URL, targetFolder: URL, newName: String)] = []
        var remote: [(source: URL, targetFolder: URL, newName: String)] = []
        for item in items {
            if isOnRemoteVolume(item.targetFolder) {
                remote.append(item)
            } else {
                local.append(item)
            }
        }

        var outcomes: [RenameOutcome] = []
        if !local.isEmpty {
            outcomes.append(contentsOf: moveAndRenameViaFinder(local))
        }
        if !remote.isEmpty {
            outcomes.append(contentsOf: moveAndRenameViaFileManager(remote))
        }
        return outcomes
    }

    private func moveAndRenameViaFinder(_ items: [(source: URL, targetFolder: URL, newName: String)]) -> [RenameOutcome] {
        if let outcomes = tryBatchMoveAndRename(items) {
            return outcomes
        }

        // Single-block batch failed — retry per item, checking for already-
        // completed work the same way batchRename does.
        return items.map { item in
            let toURL = item.targetFolder.appendingPathComponent(item.newName)
            let fm = FileManager.default
            if !fm.fileExists(atPath: item.source.path) && fm.fileExists(atPath: toURL.path) {
                return .renamed(from: item.source, to: toURL)
            }
            do {
                try moveAndRenameSingle(source: item.source, targetFolder: item.targetFolder, newName: item.newName)
                return .renamed(from: item.source, to: toURL)
            } catch {
                return .failed(item.source, error: error.localizedDescription)
            }
        }
    }

    /// Two-phase path for network destinations: move via FileManager
    /// (reliable on SMB), then rename via Finder so the final visible
    /// name lands in Finder's undo stack. The move itself is not in
    /// Finder's undo — Cmd-Z in Finder will revert the rename only.
    private func moveAndRenameViaFileManager(_ items: [(source: URL, targetFolder: URL, newName: String)]) -> [RenameOutcome] {
        struct Moved {
            let originalSource: URL
            let intermediate: URL
            let finalName: String
        }
        var moved: [Moved] = []
        var outcomes: [RenameOutcome] = []

        for item in items {
            // Intermediate name uses a UUID prefix to dodge collisions
            // against (a) an existing file in the target folder with the
            // source's basename, and (b) another item in this same batch
            // whose source happens to share a basename. The Finder rename
            // pass below sets the canonical name. Use a short, plain UUID
            // (no original-name suffix) so we don't carry exotic
            // characters through SMB's filename-validation pass on the
            // first hop — the final name is set by Finder afterwards.
            let intermediateName = "fttmp-\(UUID().uuidString).tmp"
            let intermediate = item.targetFolder.appendingPathComponent(intermediateName)
            do {
                try crossVolumeMove(from: item.source, to: intermediate)
                moved.append(Moved(originalSource: item.source, intermediate: intermediate, finalName: item.newName))
            } catch {
                log.error("cross-volume move failed src=\(item.source.path, privacy: .public) dst=\(intermediate.path, privacy: .public) err=\(String(describing: error), privacy: .public)")
                outcomes.append(.failed(item.source, error: friendlyError(error)))
            }
        }

        if moved.isEmpty { return outcomes }

        let renameInputs = moved.map { (from: $0.intermediate, to: $0.finalName) }
        let renameOutcomes = batchRename(renameInputs)

        let sourceByIntermediate: [URL: URL] = Dictionary(
            uniqueKeysWithValues: moved.map { ($0.intermediate, $0.originalSource) }
        )
        for outcome in renameOutcomes {
            switch outcome {
            case .renamed(let from, let to):
                outcomes.append(.renamed(from: sourceByIntermediate[from] ?? from, to: to))
            case .failed(let url, let error):
                // Rename failed but the move succeeded — file is sitting
                // in the destination under its intermediate name. Surface
                // that explicitly so the user can recover it.
                let original = sourceByIntermediate[url] ?? url
                outcomes.append(.failed(original, error: "Moved to \(url.path) but rename failed: \(error)"))
            case .skipped(let url, let reason):
                outcomes.append(.skipped(sourceByIntermediate[url] ?? url, reason: reason))
            }
        }
        return outcomes
    }

    /// Cross-volume move that survives SMB's metadata limitations.
    ///
    /// Tries three strategies in order of decreasing optimism:
    ///   1. `FileManager.moveItem` — fast path; works on local volumes
    ///      and lenient SMB servers.
    ///   2. `copyfile(COPYFILE_DATA)` + remove — POSIX-level, claims to
    ///      copy only the data fork but still touches some destination
    ///      metadata that strict SMB servers (e.g. some NAS firmwares)
    ///      reject with ENOTSUP.
    ///   3. Hand-rolled `read()`/`write()` stream copy + remove — bytes
    ///      and nothing else, the lowest common denominator. Every
    ///      filesystem in existence supports this.
    private func crossVolumeMove(from source: URL, to destination: URL) throws {
        do {
            try FileManager.default.moveItem(at: source, to: destination)
            return
        } catch {
            log.info("moveItem failed, retrying with copyfile: \(String(describing: error), privacy: .public)")
        }

        if copyfileDataOnly(from: source, to: destination) {
            try FileManager.default.removeItem(at: source)
            return
        }

        // Streamed byte copy. Mirrors what `dd` / `cat > file` would do
        // — the destination FS never sees any metadata op besides the
        // bytes being appended.
        do {
            try streamCopy(from: source, to: destination)
            try FileManager.default.removeItem(at: source)
        } catch {
            // Best-effort cleanup of partial destination so we don't
            // leave a half-written intermediate cluttering the share.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Returns `true` on success. Logs (but doesn't throw) on failure so
    /// the caller can fall through to the next strategy.
    private func copyfileDataOnly(from source: URL, to destination: URL) -> Bool {
        let result = source.path.withCString { srcPath in
            destination.path.withCString { dstPath in
                copyfile(srcPath, dstPath, nil, copyfile_flags_t(COPYFILE_DATA))
            }
        }
        if result == 0 { return true }
        let code = errno
        let msg = String(cString: strerror(code))
        log.info("copyfile failed (errno \(code, privacy: .public): \(msg, privacy: .public)), retrying with stream copy")
        // Some SMB servers leave a zero-byte stub from the partial
        // attempt — clean it up so the stream-copy step starts fresh.
        try? FileManager.default.removeItem(at: destination)
        return false
    }

    /// Pure byte copy using `open`/`read`/`write`. No xattr, no ACL, no
    /// resource fork, no `fchmod`, no `setattrlist` — just bytes.
    private func streamCopy(from source: URL, to destination: URL) throws {
        let srcFD = source.path.withCString { open($0, O_RDONLY) }
        if srcFD < 0 {
            throw posixError("open source")
        }
        defer { close(srcFD) }

        // Flags match `touch(1)` exactly — `O_WRONLY | O_CREAT`, mode
        // 0o666 — which is the most permissive form macOS's smbfs can
        // translate. Both O_TRUNC (`OVERWRITE_IF`) and O_EXCL
        // (`CREATE_NEW`) are rejected with ENOTSUP by some NAS
        // firmwares; bare O_CREAT (`OPEN_IF`) is what those servers
        // actually accept. Our destination is a UUID name, so we don't
        // need O_EXCL to guarantee freshness, and we don't need O_TRUNC
        // because the file shouldn't exist yet — but defensively
        // ftruncate to 0 anyway, in case a prior failed attempt left a
        // zero-or-partial-byte stub that the cleanup couldn't remove.
        let dstFD = destination.path.withCString { open($0, O_WRONLY | O_CREAT, 0o666) }
        if dstFD < 0 {
            throw posixError("open destination")
        }
        if ftruncate(dstFD, 0) != 0 {
            // Non-fatal: log and continue. ftruncate may also be
            // ENOTSUP on the share, but if the file is brand-new the
            // size is already 0 and the subsequent writes will be
            // correct.
            log.info("ftruncate on SMB destination returned errno \(errno, privacy: .public) — continuing")
        }
        defer { close(dstFD) }

        let bufSize = 1 << 20 // 1 MiB
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buffer.deallocate() }

        while true {
            let n = read(srcFD, buffer, bufSize)
            if n < 0 {
                if errno == EINTR { continue }
                throw posixError("read")
            }
            if n == 0 { break }

            var remaining = n
            var ptr = buffer
            while remaining > 0 {
                let w = write(dstFD, ptr, remaining)
                if w < 0 {
                    if errno == EINTR { continue }
                    throw posixError("write")
                }
                remaining -= w
                ptr = ptr.advanced(by: w)
            }
        }
    }

    private func posixError(_ op: String) -> NSError {
        let code = errno
        let msg = String(cString: strerror(code))
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(op) failed: \(msg)"
        ])
    }

    /// Unwraps NSError userInfo to produce a message that names the
    /// actual failure (POSIX errno, underlying error) instead of the
    /// stock "X couldn't be moved to Y" Cocoa shell.
    private func friendlyError(_ error: Error) -> String {
        let ns = error as NSError
        var parts: [String] = [ns.localizedDescription]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            let u = "\(underlying.domain) \(underlying.code): \(underlying.localizedDescription)"
            parts.append(u)
        }
        if ns.domain == NSPOSIXErrorDomain {
            parts.append("errno \(ns.code)")
        }
        return parts.joined(separator: " — ")
    }

    private func isOnRemoteVolume(_ url: URL) -> Bool {
        let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        if let values = try? folder.resourceValues(forKeys: [.volumeIsLocalKey]),
           let isLocal = values.volumeIsLocal {
            return !isLocal
        }
        return false
    }

    // MARK: - Private

    private func tryBatchScript(_ renames: [(from: URL, to: String)]) -> [RenameOutcome]? {
        var lines = ["tell application \"Finder\""]
        for r in renames {
            // Reference the item via its parent folder + filename rather than coercing the
            // POSIX path to an alias. Network volumes (NAS) can produce alias values that
            // Finder refuses to rename ("Can't set alias … to …"); going through the
            // parent folder avoids alias resolution entirely. See issue #8.
            let parent = r.from.deletingLastPathComponent().path
            let name = finderName(from: r.from.lastPathComponent)
            let newName = finderName(from: r.to)
            lines.append("  set name of (item \(asString(name)) of folder (POSIX file \(asString(parent)))) to \(asString(newName))")
        }
        lines.append("end tell")

        do {
            try runScript(lines.joined(separator: "\n"))
            return renames.map { r in
                let toURL = r.from.deletingLastPathComponent().appendingPathComponent(r.to)
                return .renamed(from: r.from, to: toURL)
            }
        } catch {
            return nil
        }
    }

    private func tryBatchMoveAndRename(_ items: [(source: URL, targetFolder: URL, newName: String)]) -> [RenameOutcome]? {
        var lines = ["tell application \"Finder\""]
        for (i, item) in items.enumerated() {
            let varName = "movedItem_\(i)"
            let sourcePath = item.source.path
            let folderPath = item.targetFolder.path
            let newName = finderName(from: item.newName)
            lines.append("  set \(varName) to move (POSIX file \(asString(sourcePath))) to folder (POSIX file \(asString(folderPath)))")
            lines.append("  set name of \(varName) to \(asString(newName))")
        }
        lines.append("end tell")

        do {
            try runScript(lines.joined(separator: "\n"))
            return items.map { item in
                let toURL = item.targetFolder.appendingPathComponent(item.newName)
                return .renamed(from: item.source, to: toURL)
            }
        } catch {
            return nil
        }
    }

    private func moveAndRenameSingle(source: URL, targetFolder: URL, newName: String) throws {
        let folderPath = targetFolder.path
        let name = finderName(from: newName)
        let script = """
            tell application "Finder"
                set movedItem to move (POSIX file \(asString(source.path))) to folder (POSIX file \(asString(folderPath)))
                set name of movedItem to \(asString(name))
            end tell
        """
        try runScript(script)
    }

    private func renameSingle(from url: URL, to newName: String) throws {
        let parent = url.deletingLastPathComponent().path
        let name = finderName(from: url.lastPathComponent)
        let target = finderName(from: newName)
        let source = """
            tell application "Finder"
                set name of (item \(asString(name)) of folder (POSIX file \(asString(parent)))) to \(asString(target))
            end tell
        """
        try runScript(source)
    }

    /// Translates a POSIX filename into the form Finder uses for its `name`
    /// property. macOS stores `/` in user-visible names as `:` at the POSIX
    /// layer, so a file the user sees as "Foo / Bar" has a POSIX name of
    /// "Foo : Bar". Finder's AppleScript model uses the user-visible form;
    /// without this swap, files containing `/` in their Finder name can't
    /// be located by `item "…"`.
    private func finderName(from posixName: String) -> String {
        posixName.replacingOccurrences(of: ":", with: "/")
    }

    @discardableResult
    private func runScript(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else {
            throw FinderBridgeError.scriptFailed("Could not compile script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let info = errorInfo {
            let number = (info["NSAppleScriptErrorNumber"] as? Int) ?? 0
            let message = (info["NSAppleScriptErrorMessage"] as? String) ?? "Unknown error"
            if number == -1743 {
                throw FinderBridgeError.automationDenied
            }
            // Finder error -10000 ("The operation can't be completed because
            // you don't have the necessary permission.") is what TCC bubbles
            // up when the AppleScript caller lacks Full Disk Access for the
            // destination of a move. The exact wording varies across
            // localizations, so match on both the AS error code and the
            // English substring as a belt-and-suspenders check.
            if number == -10000 || message.contains("don't have the necessary permission") {
                throw FinderBridgeError.destinationNotPermitted
            }
            throw FinderBridgeError.scriptFailed(message)
        }
        return result
    }

    // Produces an AppleScript string literal that safely encodes s,
    // even when s contains double-quote characters.
    private func asString(_ s: String) -> String {
        let parts = s.components(separatedBy: "\"")
        if parts.count == 1 { return "\"\(s)\"" }
        return parts.map { "\"\($0)\"" }.joined(separator: " & quote & ")
    }
}
