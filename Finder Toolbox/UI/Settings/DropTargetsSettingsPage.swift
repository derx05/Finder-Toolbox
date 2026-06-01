import SwiftUI

/// Settings page for the drag-time drop-targets feature (issue #29).
///
/// Off by default. When enabled, every open Finder window grows a small
/// drop overlay in its bottom-right corner while a file drag is in
/// progress; dropping on the overlay routes the file through the same
/// rename pipeline as the global hotkey and then moves it into that
/// folder via a single Apple Events `tell Finder` block (so the move
/// lands in Finder's native undo stack).
struct DropTargetsSettingsPage: View {
    @AppStorage(DefaultsKeys.dropTargetsEnabled) private var enabled = false
    @StateObject private var permissions = PermissionsManager.shared

    var body: some View {
        Form {
            Section("Drop Targets") {
                Toggle("Show drop overlays while dragging files", isOn: $enabled)
                    .toggleStyle(.switch)

                Text("When a file drag begins anywhere on the system, a small overlay appears in the bottom-right corner of each visible Finder window. Drop a file on an overlay to rename it with the smart-date pipeline and move it into that window's folder, in one step.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Permissions") {
                permissionRow(
                    title: "Automation — Finder",
                    detail: "Required. Used to enumerate open Finder windows and to move + rename the dropped file in one Apple Events block (so the operation lands in Finder's native undo stack).",
                    granted: permissions.finderAutomationStatus == .authorized
                )

                permissionRow(
                    title: "Full Disk Access",
                    detail: "Optional, but required when dropping into protected locations (Desktop, Documents, Downloads, iCloud Drive, …). Without it those drops fail with a permission error from Finder.",
                    granted: permissions.fullDiskAccessStatus == .authorized
                )

                HStack {
                    Spacer()
                    Button("Open Permissions…") {
                        NotificationCenter.default.post(name: .openPermissionsSettingsPage, object: nil)
                    }
                }
            }

            Section("How it works") {
                bullet("Energy-light", "No polling. A global mouse-event monitor and the drag pasteboard's change count drive the state machine — idle the rest of the time.")
                bullet("File promises", "Supports Mail.app, Safari downloads, Photos exports, and anything using NSFilePromiseProvider — the file is materialized into a temp folder before being routed through the rename pipeline.")
                bullet("Occlusion-aware", "Finder windows whose bottom-right corner is covered by another window are skipped — the overlay would be unreachable anyway.")
            }
        }
        .formStyle(.grouped)
    }

    private func permissionRow(title: String, detail: String, granted: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).bold()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Notification.Name {
    /// Posted by the Drop Targets page when the user clicks the
    /// "Open Permissions…" shortcut. The SettingsView root listens and
    /// switches the selected page to `.permissions`.
    static let openPermissionsSettingsPage = Notification.Name("FinderToolbox.openPermissionsSettingsPage")
}
