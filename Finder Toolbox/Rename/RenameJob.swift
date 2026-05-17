import Foundation

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
