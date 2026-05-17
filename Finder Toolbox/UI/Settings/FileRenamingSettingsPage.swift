import SwiftUI
import Combine

/// File-renaming feature settings: global hotkey, cleanup flags, .eml date
/// extraction, and the permission-denied banner.
struct FileRenamingSettingsPage: View {
    @StateObject private var permissions = PermissionsManager.shared

    @State private var isRecordingHotkey = false
    @State private var hotkeyLabel = HotkeyManager.shared.currentShortcutLabel

    @AppStorage(DefaultsKeys.cleanupTrimStem) private var trimStemWhitespace = false
    @AppStorage(DefaultsKeys.emlUseDateHeader) private var emlUseDateHeader = true

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRow(
                    label: hotkeyLabel,
                    isRecording: $isRecordingHotkey,
                    onNewShortcut: { keyCode, modifiers in
                        HotkeyManager.shared.update(keyCode: keyCode, modifiers: modifiers)
                        hotkeyLabel = HotkeyManager.shared.currentShortcutLabel
                    }
                )
            }

            Section("Cleanup") {
                LabeledContent {
                    Toggle("", isOn: $trimStemWhitespace)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Remove space before extension")
                        InfoPopover(
                            title: "Remove space before extension",
                            detail: "Strips a trailing space from the filename stem before renaming.",
                            exampleBefore: "\"Report .pdf\"",
                            exampleAfter: "\"Report.pdf\""
                        )
                    }
                }
            }

            Section("Email (.eml)") {
                LabeledContent {
                    Toggle("", isOn: $emlUseDateHeader)
                        .labelsHidden()
                        .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Extract date from email headers")
                        InfoPopover(
                            title: "Email date extraction",
                            detail: "Reads the Date: header from the .eml file and uses it as the file's date prefix instead of the filesystem modification date.",
                            exampleBefore: "\"Invoice.eml\"",
                            exampleAfter: "\"2024-03-15 Invoice.eml\""
                        )
                    }
                }
            }

            if permissions.finderAutomationStatus == .denied {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Finder automation permission denied.")
                        Spacer()
                        Button("Open Settings") {
                            permissions.openSystemSettings()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await permissions.checkPermission()
        }
    }
}
