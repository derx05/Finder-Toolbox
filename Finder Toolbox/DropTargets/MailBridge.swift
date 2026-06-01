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

    /// Per-message records describing exactly what the user is dragging.
    /// Present even when the Mail viewer is in conversation/thread mode,
    /// where `selection` (the AppleScript property) returns the entire
    /// thread instead of the one bubble the user grabbed.
    static let automatorType = NSPasteboard.PasteboardType("com.apple.mail.PasteboardTypeAutomator")

    static func isMailDrag(_ pb: NSPasteboard) -> Bool {
        pb.types?.contains(messageTransferType) == true
    }

/// One row from `PasteboardTypeAutomator` — identifies a single
    /// dragged Mail message by Mail's internal numeric id plus the
    /// mailbox/account it lives in. Subject is carried along for the
    /// post-export rename.
    struct DraggedMessage {
        let account: String
        let mailbox: String
        let id: Int
        let subject: String
    }

    /// Decodes `PasteboardTypeAutomator`. Returns an empty array if the
    /// type isn't present or the payload doesn't match the expected
    /// shape — callers fall back to the `selection` path in that case.
    static func draggedMessages(from pb: NSPasteboard) -> [DraggedMessage] {
        guard let data = pb.data(forType: automatorType),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let arr = plist as? [[String: Any]]
        else { return [] }

        var out: [DraggedMessage] = []
        for dict in arr {
            guard let account = dict["account"] as? String,
                  let mailbox = dict["mailbox"] as? String,
                  let subject = dict["subject"] as? String
            else { continue }
            let id: Int
            if let n = dict["id"] as? Int { id = n }
            else if let n = (dict["id"] as? NSNumber)?.intValue { id = n }
            else { continue }
            out.append(DraggedMessage(account: account, mailbox: mailbox, id: id, subject: subject))
        }
        return out
    }

    /// Writes the messages identified by `dragged` as `.eml` files
    /// into `dir`. If `dragged` is empty, falls back to Mail's current
    /// `selection` (preserves the original behavior for drag sources
    /// that don't advertise the Automator pasteboard type).
    ///
    /// **MUST be called off the main thread** — `NSAppleScript` blocks
    /// for the duration of the AppleEvent round-trip with Mail.
    static func saveMessages(_ dragged: [DraggedMessage], to dir: URL) throws -> [URL] {
        if dragged.isEmpty {
            return try saveSelection(to: dir)
        }
        return try saveExplicit(dragged, to: dir)
    }

    private static func saveExplicit(_ dragged: [DraggedMessage], to dir: URL) throws -> [URL] {
        let escapedDir = escapeForAppleScript(dir.path)

        // The mailbox name on the pasteboard (e.g. "INBOX.Sent") often
        // doesn't match how Mail's AppleScript model exposes the
        // mailbox — special mailboxes (Sent/Drafts/Trash/Junk) and
        // nested IMAP folders are common offenders. So we ignore the
        // mailbox label and walk every mailbox of the account
        // (recursing into nested mailboxes) until we find the message
        // by its numeric id.
        var perMessageBlocks: [String] = []
        for m in dragged {
            let escapedAccount = escapeForAppleScript(m.account)
            let block = """
                try
                    set msg to my findMessageInAccount("\(escapedAccount)", \(m.id))
                    if msg is missing value then error "message id \(m.id) not found in any mailbox of account \(escapedAccount)"
                    set theSource to source of msg
                    set uuidStr to (do shell script "/usr/bin/uuidgen")
                    set theFile to destDir & "/" & uuidStr & ".eml"
                    set fileRef to (open for access (POSIX file theFile) with write permission)
                    try
                        set eof fileRef to 0
                        write theSource to fileRef
                    end try
                    close access fileRef
                    set output to output & uuidStr & tab & "\(m.id)" & linefeed
                on error errMsg
                    set output to output & "ERR\\t\(m.id)\\t" & errMsg & linefeed
                end try
            """
            perMessageBlocks.append(block)
        }

        let script = """
        tell application "Mail"
            set destDir to "\(escapedDir)"
            set output to ""
        \(perMessageBlocks.joined(separator: "\n"))
            return output
        end tell

        on findMessageInAccount(acctName, targetID)
            tell application "Mail"
                try
                    repeat with mbx in (every mailbox of account acctName)
                        set found to my findMessageInMailbox(mbx, targetID)
                        if found is not missing value then return found
                    end repeat
                end try
            end tell
            return missing value
        end findMessageInAccount

        on findMessageInMailbox(mbx, targetID)
            tell application "Mail"
                try
                    return (first message of mbx whose id is targetID)
                end try
                try
                    repeat with subMbx in (every mailbox of mbx)
                        set found to my findMessageInMailbox(subMbx, targetID)
                        if found is not missing value then return found
                    end repeat
                end try
            end tell
            return missing value
        end findMessageInMailbox
        """

        let raw = try runScript(script)

        // Map UUID → subject from the Swift-side records so we don't
        // have to round-trip the (possibly quote-laden) subject through
        // AppleScript output.
        let subjectByID: [Int: String] = Dictionary(uniqueKeysWithValues: dragged.map { ($0.id, $0.subject) })

        var urls: [URL] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "ERR" {
                log.error("MailBridge: per-message error: \(String(rawLine), privacy: .public)")
                continue
            }
            let uuidStr = parts[0]
            let id = Int(parts[1]) ?? -1
            let subject = subjectByID[id] ?? "Mail message"
            if let url = finalizeExportedMessage(uuid: uuidStr, subject: subject, in: dir) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func saveSelection(to dir: URL) throws -> [URL] {
        let escapedDir = escapeForAppleScript(dir.path)
        let script = """
        tell application "Mail"
            set theMessages to selection
            set destDir to "\(escapedDir)"
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

        let raw = try runScript(script)
        var urls: [URL] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            if let url = finalizeExportedMessage(uuid: parts[0], subject: parts[1], in: dir) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func runScript(_ source: String) throws -> String {
        guard let appleScript = NSAppleScript(source: source) else {
            throw NSError(domain: "MailBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compile AppleScript"])
        }
        var errorInfo: NSDictionary?
        let result = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? String(describing: errorInfo)
            log.error("MailBridge: AppleScript error: \(msg, privacy: .public)")
            throw NSError(domain: "MailBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return result.stringValue ?? ""
    }

    /// Renames the UUID-named export to a subject-derived filename.
    /// Returns the final URL, or nil if Mail never wrote the file.
    private static func finalizeExportedMessage(uuid: String, subject: String, in dir: URL) -> URL? {
        let source = dir.appendingPathComponent("\(uuid).eml")
        guard FileManager.default.fileExists(atPath: source.path) else {
            log.error("MailBridge: Mail reported \(uuid, privacy: .public) but file is missing")
            return nil
        }
        let safe = sanitize(subject)
        let target = uniquify(dir.appendingPathComponent("\(safe).eml"))
        do {
            try FileManager.default.moveItem(at: source, to: target)
            return target
        } catch {
            log.error("MailBridge: rename to subject failed (\(error.localizedDescription, privacy: .public)) — keeping UUID name")
            return source
        }
    }

    private static func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
