import Foundation

enum FinderBridgeError: LocalizedError {
    case noSelection
    case scriptFailed(String)
    case automationDenied

    var errorDescription: String? {
        switch self {
        case .noSelection:
            "No files are selected in Finder."
        case .scriptFailed(let msg):
            "AppleScript error: \(msg)"
        case .automationDenied:
            "Automation access to Finder has not been granted. Open System Settings → Privacy & Security → Automation to enable it."
        }
    }
}

// All methods run synchronous NSAppleScript calls — must be called off the main thread.
actor FinderBridge {

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
