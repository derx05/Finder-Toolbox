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
