import AppKit
import SwiftUI

/// Auto-dismissing toast shown after every drop when
/// `DefaultsKeys.showDropDebugPopups` is on. Surfaces enough detail to
/// diagnose the "I heard a copy sound but the file isn't there" case
/// without interrupting the workflow with a modal dialog.
///
/// The panel auto-dismisses after `autoDismissSeconds`; clicking it
/// pins it (cancels the dismiss timer). A "Copy details" button copies
/// the same text DebugLog would record, so the user can paste it into a
/// bug report.
@MainActor
enum DropResultToast {
    private static let autoDismissSeconds: TimeInterval = 6
    private static var current: NSPanel?

    static func showIfEnabled(targetFolder: URL,
                              operation: DropOperation,
                              inputCount: Int,
                              renamed: Int,
                              failed: [(URL, String)],
                              skipped: Int) {
        guard UserDefaults.standard.bool(forKey: DefaultsKeys.showDropDebugPopups) else { return }
        show(targetFolder: targetFolder, operation: operation,
             inputCount: inputCount, renamed: renamed,
             failed: failed, skipped: skipped)
    }

    private static func show(targetFolder: URL,
                             operation: DropOperation,
                             inputCount: Int,
                             renamed: Int,
                             failed: [(URL, String)],
                             skipped: Int) {
        current?.orderOut(nil)

        let info = ToastInfo(
            folder: targetFolder.lastPathComponent,
            folderPath: targetFolder.path,
            operation: operation,
            inputCount: inputCount,
            renamed: renamed,
            skipped: skipped,
            failed: failed.map { ($0.0.lastPathComponent, $0.1) }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false

        let host = NSHostingView(
            rootView: DropResultToastView(
                info: info,
                onCopy: { copyDetails(info) },
                onDismiss: { dismiss() }
            )
        )
        host.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = host

        let fittingSize = host.fittingSize
        let size = NSSize(width: max(360, fittingSize.width), height: max(60, fittingSize.height))
        panel.setContentSize(size)

        // Position near the top-right of the screen containing the cursor.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                     ?? NSScreen.main
                     ?? NSScreen.screens.first
        if let screen {
            let visible = screen.visibleFrame
            let origin = NSPoint(
                x: visible.maxX - size.width - 16,
                y: visible.maxY - size.height - 16
            )
            panel.setFrameOrigin(origin)
        }

        panel.orderFrontRegardless()
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissSeconds) { [weak panel] in
            guard panel === current else { return }
            dismiss()
        }
    }

    static func dismiss() {
        current?.orderOut(nil)
        current = nil
    }

    private static func copyDetails(_ info: ToastInfo) {
        let lines = [
            "Drop target: \(info.folder) — \(info.folderPath)",
            "Operation: \(info.operation)",
            "Input items: \(info.inputCount)",
            "Renamed/transferred: \(info.renamed)",
            "Skipped: \(info.skipped)",
            "Failed: \(info.failed.count)"
        ] + info.failed.map { "  - \($0.0): \($0.1)" }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

struct ToastInfo {
    let folder: String
    let folderPath: String
    let operation: DropOperation
    let inputCount: Int
    let renamed: Int
    let skipped: Int
    let failed: [(String, String)]
}

private struct DropResultToastView: View {
    let info: ToastInfo
    let onCopy: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: headerIcon)
                    .foregroundStyle(headerTint)
                Text(headerTitle)
                    .font(.system(.body, design: .default).weight(.semibold))
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("→ \(info.folder)")
                    .font(.system(.callout).weight(.medium))
                Text(verbatim: "\(info.operation) · in \(info.inputCount) · renamed \(info.renamed) · skipped \(info.skipped) · failed \(info.failed.count)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !info.failed.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(info.failed.prefix(4).enumerated()), id: \.offset) { _, item in
                        Text("✗ \(item.0): \(item.1)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    }
                    if info.failed.count > 4 {
                        Text("… and \(info.failed.count - 4) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Copy details", action: onCopy)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(radius: 8, y: 2)
    }

    private var headerIcon: String {
        if !info.failed.isEmpty { return "exclamationmark.triangle.fill" }
        if info.renamed == 0 && info.skipped == 0 { return "questionmark.circle.fill" }
        return "checkmark.circle.fill"
    }

    private var headerTint: Color {
        if !info.failed.isEmpty { return .red }
        if info.renamed == 0 && info.skipped == 0 { return .orange }
        return .green
    }

    private var headerTitle: String {
        if !info.failed.isEmpty { return "Drop completed with errors" }
        if info.renamed == 0 && info.skipped == 0 { return "Drop produced no result" }
        return "Drop succeeded"
    }
}
