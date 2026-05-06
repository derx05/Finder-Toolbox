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

        // Fall back to individual scripts so we get per-file error info.
        return renames.map { rename in
            do {
                try renameSingle(from: rename.from, to: rename.to)
                let toURL = rename.from.deletingLastPathComponent().appendingPathComponent(rename.to)
                return .renamed(from: rename.from, to: toURL)
            } catch {
                return .failed(rename.from, error: error.localizedDescription)
            }
        }
    }

    // MARK: - Private

    private func tryBatchScript(_ renames: [(from: URL, to: String)]) -> [RenameOutcome]? {
        var lines = ["tell application \"Finder\""]
        for r in renames {
            // "as alias" coerces the file reference to an alias that Finder's rename command accepts.
            lines.append("  set name of (POSIX file \(asString(r.from.path)) as alias) to \(asString(r.to))")
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

    private func renameSingle(from url: URL, to newName: String) throws {
        let source = """
            tell application "Finder"
                set name of (POSIX file \(asString(url.path)) as alias) to \(asString(newName))
            end tell
        """
        try runScript(source)
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
