import AppKit
import Foundation

/// Per-PDF prompt for date conflicts and missing-date situations.
///
/// Two variants share the same window shape:
/// - `.conflict` — heuristic text scan and PDF metadata disagree by more than
///   the configured tolerance. User picks one of the two candidate dates.
/// - `.noDate` — heuristic found nothing; only the metadata date is available.
///   User confirms the metadata date or falls back to today.
///
/// Both variants offer "Apply this choice to remaining PDFs in this batch"
/// via a checkbox accessoryView. The dialog returns a `Disposition` (which
/// *side* the user picked) rather than a concrete date so "apply to remaining"
/// means "use heuristic for everyone else", not "use this literal date".
enum PdfConflictDialog {
    enum Disposition {
        case heuristic
        case metadata
        case today
    }

    struct Response {
        /// `nil` means the user cancelled the entire batch.
        let disposition: Disposition?
        /// When true, the caller should reuse this disposition for every
        /// remaining decision of the same kind without prompting again.
        let applyToRemaining: Bool
    }

    /// Shown when both heuristic and metadata produced dates that disagree.
    static func askConflict(
        decision: PdfPendingDecision,
        index: Int,
        total: Int
    ) -> Response {
        guard let heuristic = decision.heuristic, let metadata = decision.metadata else {
            // `.conflict` requires both — defensive fallback.
            return Response(disposition: nil, applyToRemaining: false)
        }

        let alert = NSAlert()
        alert.messageText = total > 1
            ? "PDF date conflict (\(index) of \(total))"
            : "PDF date conflict"
        alert.informativeText = """
            \(decision.originalURL.lastPathComponent) has two candidate dates and they disagree.

            Document text suggests \(format(heuristic)).
            File metadata suggests \(format(metadata)).
            """
        alert.alertStyle = .informational

        // First button is the default — "document text" is the right answer
        // for invoices the vast majority of the time.
        alert.addButton(withTitle: "Use \(format(heuristic)) (document)")
        alert.addButton(withTitle: "Use \(format(metadata)) (metadata)")
        let cancel = alert.addButton(withTitle: "Cancel Batch")
        cancel.keyEquivalent = "\u{1b}"

        let checkbox = makeApplyToRemainingCheckbox(total: total)
        alert.accessoryView = checkbox

        let applyToRemaining = checkbox?.state == .on
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return Response(disposition: .heuristic, applyToRemaining: checkbox?.state == .on)
        case .alertSecondButtonReturn:
            return Response(disposition: .metadata, applyToRemaining: checkbox?.state == .on)
        default:
            _ = applyToRemaining  // silence unused warning when both checkbox reads happen post-modal
            return Response(disposition: nil, applyToRemaining: false)
        }
    }

    /// Shown when the heuristic found no date and only metadata is available
    /// (or nothing at all, in which case only the "today" choice is offered).
    static func askNoDate(
        decision: PdfPendingDecision,
        index: Int,
        total: Int
    ) -> Response {
        let alert = NSAlert()
        alert.messageText = total > 1
            ? "PDF has no detected date (\(index) of \(total))"
            : "PDF has no detected date"

        if let metadata = decision.metadata {
            alert.informativeText = """
                \(decision.originalURL.lastPathComponent) — no invoice date was found in the document text.

                File metadata suggests \(format(metadata)). You can also use today's date.
                """
            alert.addButton(withTitle: "Use \(format(metadata)) (metadata)")
            alert.addButton(withTitle: "Use today's date")
        } else {
            alert.informativeText = "\(decision.originalURL.lastPathComponent) — no date found anywhere in this PDF."
            alert.addButton(withTitle: "Use today's date")
        }
        let cancel = alert.addButton(withTitle: "Cancel Batch")
        cancel.keyEquivalent = "\u{1b}"

        alert.alertStyle = .informational
        let checkbox = makeApplyToRemainingCheckbox(total: total)
        alert.accessoryView = checkbox

        let response = alert.runModal()
        let apply = checkbox?.state == .on

        if decision.metadata != nil {
            switch response {
            case .alertFirstButtonReturn:
                return Response(disposition: .metadata, applyToRemaining: apply)
            case .alertSecondButtonReturn:
                return Response(disposition: .today, applyToRemaining: apply)
            default:
                return Response(disposition: nil, applyToRemaining: false)
            }
        } else {
            switch response {
            case .alertFirstButtonReturn:
                return Response(disposition: .today, applyToRemaining: apply)
            default:
                return Response(disposition: nil, applyToRemaining: false)
            }
        }
    }

    // MARK: - Private

    private static func makeApplyToRemainingCheckbox(total: Int) -> NSButton? {
        guard total > 1 else { return nil }
        let checkbox = NSButton(checkboxWithTitle: "Apply this choice to remaining PDFs in this batch",
                                target: nil,
                                action: nil)
        checkbox.state = .off
        checkbox.sizeToFit()
        let size = checkbox.frame.size
        // Pad the width so AppKit doesn't crop the label on the right edge
        // when the alert auto-sizes its accessory column.
        checkbox.frame = NSRect(x: 0, y: 0, width: max(size.width, 360), height: size.height + 4)
        return checkbox
    }

    private static func format(_ components: DateComponents) -> String {
        guard let y = components.year, let m = components.month, let d = components.day else {
            return "—"
        }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }
}
