import AppKit
import OSLog

/// Handles Mail.app drags via AppleScript.
///
/// Mail's file-promise implementation only fulfills against Finder.
/// For any other destination, `namesOfPromisedFilesDropped` returns a
/// placeholder UUID and Mail never writes the file — both the modern
/// (NSFilePromiseReceiver) and legacy promise contracts fail.
///
/// Mail does however put `com.apple.mail.PasteboardTypeMessageTransfer`
/// on the pasteboard whenever the drag originates in a message list,
/// and the user's Mail selection mirrors what they're dragging. So we
/// ask Mail to save its selection via AppleScript — the same approach
/// Hazel, DEVONthink, MailMate, Hookmark, and friends all use.
///
/// The Automation entitlement to Mail is already covered by the app's
/// existing `com.apple.security.automation.apple-events` entitlement
/// + `NSAppleEventsUsageDescription`. macOS will prompt the user the
/// first time Mail is targeted.
enum MailBridge {
    private static let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "drop-targets")

    /// Canonical signal that the current drag originates in Mail.
    static let messageTransferType = NSPasteboard.PasteboardType("com.apple.mail.PasteboardTypeMessageTransfer")

    static func isMailDrag(_ pb: NSPasteboard) -> Bool {
        pb.types?.contains(messageTransferType) == true
    }

    /// Writes Mail's currently selected message(s) as `.eml` files into
    /// `dir`. Files are named after the message subject (sanitised);
    /// the existing rename pipeline picks them up from there, reads the
    /// `Date:` header via `EmlDateExtractor`, and prepends the date
    /// prefix as usual.
    ///
    /// **MUST be called off the main thread** — `NSAppleScript` blocks
    /// for the duration of the AppleEvent round-trip with Mail.
    static func saveSelectedMessages(to dir: URL) throws -> [URL] {
        let dirPath = dir.path
        let escaped = dirPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Each message is first written under a UUID name (avoids any
        // AppleScript-level quoting/escaping headaches with subjects
        // that contain quotes, slashes, etc.), then renamed to a
        // subject-derived filename here in Swift where sanitisation is
        // straightforward.
        let script = """
        tell application "Mail"
            set theMessages to selection
            set destDir to "\(escaped)"
            set output to ""
            repeat with msg in theMessages
                set theSubject to subject of msg
                set theSource to source of msg
                set uuidStr to (do shell script "/usr/bin/uuidgen")
                set theFile to destDir & "/" & uuidStr & ".eml"
                set fileRef to (open for access (POSIX file theFile) with write permission)
                try
                    set eof fileRef to 0
                    write theSource to fileRef
                end try
                close access fileRef
                set output to output & uuidStr & tab & theSubject & linefeed
            end repeat
            return output
        end tell
        """

        guard let appleScript = NSAppleScript(source: script) else {
            throw NSError(domain: "MailBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript"])
        }

        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? String(describing: errorInfo)
            log.error("MailBridge: AppleScript error: \(msg, privacy: .public)")
            throw NSError(domain: "MailBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        let raw = result.stringValue ?? ""
        var urls: [URL] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let uuidStr = parts[0]
            let subject = parts[1]
            let source = dir.appendingPathComponent("\(uuidStr).eml")
            guard FileManager.default.fileExists(atPath: source.path) else {
                log.error("MailBridge: Mail reported \(uuidStr, privacy: .public) but file is missing")
                continue
            }

            let safe = sanitize(subject)
            let target = uniquify(dir.appendingPathComponent("\(safe).eml"))
            do {
                try FileManager.default.moveItem(at: source, to: target)
                urls.append(target)
            } catch {
                log.error("MailBridge: rename to subject failed (\(error.localizedDescription, privacy: .public)) — keeping UUID name")
                urls.append(source)
            }
        }
        return urls
    }

    /// HFS+/APFS allows almost anything in a filename, but Finder and
    /// most users don't want `/`, control chars, or leading/trailing
    /// whitespace. Cap at 120 chars so the eventual date-prefixed name
    /// stays within Finder's display column.
    private static func sanitize(_ subject: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?<>*|\"")
            .union(.controlCharacters)
            .union(.newlines)
        let cleaned = subject
            .components(separatedBy: illegal)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        var collapsed = cleaned
        while collapsed.contains("  ") {
            collapsed = collapsed.replacingOccurrences(of: "  ", with: " ")
        }
        if collapsed.isEmpty { return "Mail message" }
        return String(collapsed.prefix(120))
    }

    private static func uniquify(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        for i in 2...100 {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
