import SwiftUI
import AppKit

/// Settings for the insert-date hotkey: the shortcut itself, a live
/// preview of what gets typed, and the Accessibility grant the feature
/// depends on.
///
/// The permission block is on this page rather than only on the
/// Permissions page because the feature is inert without the grant and
/// the connection isn't obvious — "nothing happened when I pressed the
/// key" needs an answer where the switch is.
struct InsertDateSettingsPage: View {
    @ObservedObject private var permissions = PermissionsManager.shared

    @ObservedObject private var hotkeys = HotkeyManager.shared
    @State private var isRecording = false
    @State private var keyConflictMessage: String?

    @AppStorage(DefaultsKeys.dateFormatStyle) private var dateFormatStyleRaw = DateFormatStyle.default.rawValue

    /// Rendered from the raw default rather than a cached value so the
    /// preview follows a format change made on the File Renaming page
    /// without needing a page revisit.
    private var preview: String {
        let style = DateFormatStyle(rawValue: dateFormatStyleRaw) ?? .default
        return style.format(FilenameBuilder.todayComponents())
    }

    private var isTrusted: Bool { permissions.accessibilityStatus == .authorized }

    var body: some View {
        Form {
            Section("Insert date") {
                Toggle("Enable insert-date hotkey", isOn: Binding(
                    get: { hotkeys.insertDateEnabled },
                    set: { HotkeyManager.shared.setInsertDateEnabled($0) }
                ))
                .toggleStyle(.switch)

                Text("Types today's date into whatever text field has keyboard focus, in any app. Nothing is written to the clipboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if hotkeys.insertDateEnabled {
                    HotkeyRow(
                        title: "Insert today's date",
                        label: hotkeys.shortcutLabel(for: .insertDate),
                        isRecording: $isRecording,
                        onNewKey: { keyCode, shift in
                            if HotkeyManager.shared.updateKey(for: .insertDate, keyCode: Int(keyCode), shift: shift) {
                                keyConflictMessage = nil
                            } else {
                                let key = (shift ? "⇧" : "") + HotkeyManager.keyName(for: Int(keyCode))
                                keyConflictMessage = "\(key) is already used by another Finder Toolbox shortcut."
                            }
                        }
                    )

                    if let message = keyConflictMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("The shortcut is the shared prefix \(hotkeys.prefixLabel) plus the key recorded here (⇧ may be part of the key). Change the prefix in General settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    LabeledContent {
                        Text(preview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Inserts")
                            InfoPopover(
                                title: "Shared date format",
                                detail: "The insert-date hotkey uses the same format as the renamer, set under File Renaming → Date format. One setting, so what you type and what lands in filenames can't drift apart.",
                                exampleBefore: nil,
                                exampleAfter: nil
                            )
                        }
                    }
                }
            }

            Section("Accessibility permission") {
                LabeledContent {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isTrusted ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(isTrusted ? "Granted" : "Not granted")
                            .foregroundStyle(isTrusted ? Color.green : Color.orange)
                    }
                    .font(.callout.weight(.medium))
                } label: {
                    Text("Status")
                }

                if !isTrusted {
                    Text("macOS treats typing into another app as an accessibility capability. Until Finder Toolbox is allowed, the hotkey does nothing but show an error. After ticking the box, quit and reopen Finder Toolbox — macOS does not apply the grant to an already-running app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Request Permission") {
                            permissions.requestAccessibility()
                        }
                        Button("Open in System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { permissions.checkAccessibility() }
        // The grant is made in System Settings, so the only reliable
        // moment to re-probe is when the user comes back to us.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.checkAccessibility()
        }
    }
}
