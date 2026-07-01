import AppKit

/// Distinguishes between a Finder-style move (transfer the original file)
/// and a copy (leave the original in place). Threaded from the overlay's
/// drag-handling through to `FinderBridge` so the same pipeline can do
/// either operation.
nonisolated enum DropOperation: Sendable {
    case move
    case copy

    var nsDragOperation: NSDragOperation {
        switch self {
        case .move: .move
        case .copy: .copy
        }
    }

    var iconSymbolName: String {
        switch self {
        case .move: "arrow.down.to.line"
        case .copy: "doc.on.doc"
        }
    }

    var tintColor: NSColor {
        switch self {
        case .move: .systemBlue
        case .copy: .systemGreen
        }
    }
}

/// Terminal result of a drop, reported back from `AppController.performDrop`
/// to the overlay panel so it can show a success / failure confirmation
/// (or just fade out) before dismissing. Issue #40: the popover stays up
/// with a spinner while the transfer runs; this tells it how to finish.
nonisolated enum DropOutcome: Sendable {
    /// The transfer ran to completion. `hadFailures` is true when any
    /// individual item failed even though the batch finished — the panel
    /// shows an error flash in that case, a success check otherwise.
    case completed(hadFailures: Bool)
    /// Abandoned before any transfer ran — empty input, the app was busy,
    /// or the user cancelled a folder-mode dialog. The panel fades out
    /// with no confirmation flash.
    case cancelled
    /// Could not proceed: a permission / TCC wall the user must resolve.
    /// A recovery dialog has already been shown; the panel flashes an error.
    case failed
}
