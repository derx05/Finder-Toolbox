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

/// What to do when the PDF heuristic and the PDF metadata creation date
/// disagree by more than `pdfConflictToleranceDays`. `ask` triggers the
/// `PdfConflictDialog`; the other cases are silent and let batches run
/// hands-off.
enum PdfConflictBehavior: String, CaseIterable, Sendable {
    case ask
    case preferHeuristic = "heuristic"
    case preferMetadata  = "metadata"

    static let `default`: PdfConflictBehavior = .ask

    static func current() -> PdfConflictBehavior {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.pdfConflictBehavior),
              let v = PdfConflictBehavior(rawValue: raw) else { return .default }
        return v
    }
}

/// What to do when the PDF heuristic finds no date at all. Metadata is
/// often still available (the PDF generator stamped it); `today` matches
/// the existing `.eml` fallback behaviour for users who'd rather not
/// trust metadata.
enum PdfNoDateBehavior: String, CaseIterable, Sendable {
    case ask
    case metadata
    case today

    static let `default`: PdfNoDateBehavior = .ask

    static func current() -> PdfNoDateBehavior {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.pdfNoDateBehavior),
              let v = PdfNoDateBehavior(rawValue: raw) else { return .default }
        return v
    }
}

/// A PDF whose date couldn't be resolved silently and needs a user choice
/// before the rename batch can run. Carries both candidate dates plus the
/// pre-computed naming pieces so `applyPdfResolutions` can rebuild the
/// final filename without re-reading the PDF.
struct PdfPendingDecision: Sendable {
    enum Kind: Sendable {
        /// Heuristic and metadata both produced dates but they disagree.
        case conflict
        /// Heuristic found no date; metadata is the only candidate.
        case noDate
    }

    let originalURL: URL
    let kind: Kind
    let heuristic: DateComponents?
    let metadata: DateComponents?
    /// Filename stem stripped of any existing leading date prefix.
    let remainder: String
    /// Extension without the dot.
    let ext: String
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
