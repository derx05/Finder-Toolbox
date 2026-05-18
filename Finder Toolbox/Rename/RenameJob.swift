import Foundation

/// How a rename batch treats folders in the Finder selection.
///
/// - `flat`: rename the folder itself (e.g. add a date prefix) but leave its contents alone.
/// - `recursive`: walk into the folder, renaming all descendants (files and subfolders)
///   in addition to the folder itself.
///
/// `FolderModePreference` is the user-visible setting (which includes `.ask`); this enum
/// is the *resolved* mode that an actual batch runs in.
nonisolated enum FolderMode: Sendable {
    case flat
    case recursive
}

/// Persisted in `UserDefaults` under `DefaultsKeys.folderMode`. The runtime mode the
/// rename batch executes in is `FolderMode`; this type just adds an "ask the user" option
/// for the settings UI.
enum FolderModePreference: String, CaseIterable, Sendable {
    case ask
    case flat
    case recursive

    static let `default`: FolderModePreference = .ask

    static func current() -> FolderModePreference {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.folderMode),
              let value = FolderModePreference(rawValue: raw) else {
            return .default
        }
        return value
    }
}

struct RenameRecord: Sendable {
    let renamedURL: URL      // current path (post-rename)
    let originalName: String // filename to restore on undo
}

enum RenameOutcome: Sendable {
    case renamed(from: URL, to: URL)
    case skipped(URL, reason: SkipReason)
    case failed(URL, error: String)
}

enum SkipReason: Sendable {
    case alreadyCanonical
}

struct BatchSummary: Sendable {
    let outcomes: [RenameOutcome]

    var renamedCount: Int {
        outcomes.filter { outcome in
            if case .renamed = outcome { return true }
            return false
        }.count
    }

    var skipped: [(URL, SkipReason)] {
        outcomes.compactMap { outcome in
            if case .skipped(let u, let r) = outcome { return (u, r) }
            return nil
        }
    }

    var failed: [(URL, String)] {
        outcomes.compactMap { outcome in
            if case .failed(let u, let e) = outcome { return (u, e) }
            return nil
        }
    }

    var hasIssues: Bool { !failed.isEmpty }
    var isEmpty: Bool { outcomes.isEmpty }
}
