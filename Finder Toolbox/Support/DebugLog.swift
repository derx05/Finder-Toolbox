import Foundation
import OSLog
import Combine

/// In-app ring buffer for drop-target debugging. Captures the last
/// `maxEntries` log entries when `DefaultsKeys.dropTargetsDebugLog` is on,
/// and always mirrors to OSLog regardless of the toggle. The ring buffer
/// is what `DeveloperSettingsPage` displays; OSLog mirroring keeps
/// `log show --predicate 'subsystem == "danielammann.Finder-Toolbox"'`
/// useful when the user wants out-of-app forensics.
///
/// `log(...)` is `nonisolated` so background queues (promise polling,
/// Mail bridge, executor) can call it without hopping actors. Append
/// to the ring buffer is marshalled onto the main actor so SwiftUI
/// observers see consistent updates.
@MainActor
final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    enum Level: String, Sendable {
        case info, warning, error
    }

    struct Entry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: String
        let message: String
    }

    @Published private(set) var entries: [Entry] = []
    private let maxEntries = 500

    private init() {}

    /// Always-on OSLog mirror + opt-in ring-buffer capture. Safe to call
    /// from any actor / queue.
    nonisolated static func log(_ category: String, _ message: String, level: Level = .info) {
        let osLog = Logger(subsystem: "danielammann.Finder-Toolbox", category: category)
        switch level {
        case .info:    osLog.info("\(message, privacy: .public)")
        case .warning: osLog.notice("\(message, privacy: .public)")
        case .error:   osLog.error("\(message, privacy: .public)")
        }
        guard UserDefaults.standard.bool(forKey: DefaultsKeys.dropTargetsDebugLog) else { return }
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        Task { @MainActor in shared.append(entry) }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() { entries.removeAll() }

    /// One line per entry, ISO-8601 timestamp, suitable for the Copy/Save
    /// buttons in the Developer settings page.
    func exportText() -> String {
        entries.map { e in
            "\(Self.formatter.string(from: e.timestamp)) [\(e.level.rawValue.uppercased())] \(e.category): \(e.message)"
        }.joined(separator: "\n")
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
