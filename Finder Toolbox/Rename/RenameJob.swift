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

/// Whether folder *names* are eligible for renaming when a batch involves
/// folders (either in the selection or reached via recursive descent).
///
/// Orthogonal to `FolderMode`: scope decides whether folders are renamed,
/// mode decides whether we descend into them. With `.filesOnly` and
/// recursive mode, the batch walks into folders and renames the files
/// inside but leaves every folder name alone.
nonisolated enum FolderRenameScope: Sendable {
    case filesOnly
    case filesAndFolders
}

/// Persisted in `UserDefaults` under `DefaultsKeys.folderRenameScope`. The
/// runtime scope a batch uses is `FolderRenameScope`; this type adds an
/// "ask the user" option for the settings UI.
enum FolderRenameScopePreference: String, CaseIterable, Sendable {
    case filesOnly       = "filesOnly"
    case filesAndFolders = "filesAndFolders"
    case ask

    static let `default`: FolderRenameScopePreference = .filesOnly

    static func current() -> FolderRenameScopePreference {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.folderRenameScope),
              let value = FolderRenameScopePreference(rawValue: raw) else {
            return .default
        }
        return value
    }
}

/// Whose date wins when the filename already starts with a recognisable
/// date prefix AND content extraction (`.eml` Date header, PDF body) finds
/// a different one.
///
/// `.contentOverridesFilename` is the original 1.0.0 behaviour and stays the
/// default — invoice filenames are often stale (e.g. browser-set download
/// timestamps) and the document body is more trustworthy. `.filenameWins`
/// short-circuits content extraction entirely whenever the filename parses,
/// which is the right call for users who curate filenames manually.
enum DatePriority: String, CaseIterable, Sendable {
    case contentOverridesFilename = "content"
    case filenameWins             = "filename"

    nonisolated static let `default`: DatePriority = .contentOverridesFilename

    nonisolated static func current() -> DatePriority {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.datePriority),
              let v = DatePriority(rawValue: raw) else { return .default }
        return v
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

    nonisolated static let `default`: PdfConflictBehavior = .ask

    nonisolated static func current() -> PdfConflictBehavior {
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

    nonisolated static let `default`: PdfNoDateBehavior = .ask

    nonisolated static func current() -> PdfNoDateBehavior {
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

/// One reversible step from the most recent batch. The hotkey rename only
/// produces `.rename` entries; drop-target operations also produce `.move`
/// or `.copy` so undo can put files back where they came from (or trash a
/// copy) instead of just renaming them in place at the destination.
enum BatchAction: Sendable {
    /// Rename the item currently at `at` back to `restoreName`.
    case rename(at: URL, restoreName: String)
    /// Move the item currently at `currentURL` back to `originalParent`
    /// and restore `originalName`.
    case move(currentURL: URL, originalParent: URL, originalName: String)
    /// Send the copy at `copyURL` to the trash. Recursive descendant
    /// renames inside a copied folder are *not* recorded — trashing the
    /// folder discards them along with the copy.
    case copy(copyURL: URL)
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
