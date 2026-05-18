import SwiftUI
import Combine

/// File-renaming feature settings: global hotkey, cleanup flags, .eml date
/// extraction, folder-handling preferences, and the permission-denied banner.
struct FileRenamingSettingsPage: View {
    @StateObject private var permissions = PermissionsManager.shared

    @State private var isRecordingPrimary = false
    @State private var isRecordingSecondary = false
    @State private var primaryHotkeyLabel = HotkeyManager.shared.currentShortcutLabel
    @State private var secondaryHotkeyLabel = HotkeyManager.shared.secondaryShortcutLabel
    @State private var secondaryEnabled = HotkeyManager.shared.secondaryEnabled

    @AppStorage(DefaultsKeys.cleanupTrimStem) private var trimStemWhitespace = false
    @AppStorage(DefaultsKeys.emlUseDateHeader) private var emlUseDateHeader = true
    @AppStorage(DefaultsKeys.folderMode) private var folderModeRaw = FolderModePreference.default.rawValue
    @AppStorage(DefaultsKeys.recursiveWarnThreshold) private var recursiveWarnThreshold = AppController.defaultRecursiveWarnThreshold

    private var folderMode: Binding<FolderModePreference> {
        Binding(
            get: { FolderModePreference(rawValue: folderModeRaw) ?? .default },
            set: { folderModeRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                HotkeyRow(
                    title: secondaryEnabled ? "Rename (non-recursive)" : "Global Shortcut",
                    label: primaryHotkeyLabel,
                    isRecording: $isRecordingPrimary,
                    onNewShortcut: { keyCode, modifiers in
                        HotkeyManager.shared.update(keyCode: keyCode, modifiers: modifiers)
                        primaryHotkeyLabel = HotkeyManager.shared.currentShortcutLabel
                    }
                )

                LabeledContent {
                    Toggle("", isOn: Binding(
                        get: { secondaryEnabled },
                        set: { newValue in
                            HotkeyManager.shared.setSecondaryEnabled(newValue)
                            secondaryEnabled = newValue
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                } label: {
                    HStack(spacing: 6) {
                        Text("Use second hotkey for recursive rename")
                        InfoPopover(
                            title: "Two-hotkey mode",
                            detail: "When enabled, the primary hotkey renames only the selection (folders are renamed by their own name; contents are left alone). The second hotkey renames recursively — folders and everything inside them. Neither prompts; the choice is the keystroke.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                if secondaryEnabled {
                    HotkeyRow(
                        title: "Rename (recursive)",
                        label: secondaryHotkeyLabel,
                        isRecording: $isRecordingSecondary,
                        onNewShortcut: { keyCode, modifiers in
                            HotkeyManager.shared.updateSecondary(keyCode: keyCode, modifiers: modifiers)
                            secondaryHotkeyLabel = HotkeyManager.shared.secondaryShortcutLabel
                        }
                    )
                }
            }

            Section("Folders") {
                LabeledContent {
                    Picker("", selection: folderMode) {
                        Text("Ask each time").tag(FolderModePreference.ask)
                        Text("Rename folder only").tag(FolderModePreference.flat)
                        Text("Rename recursively").tag(FolderModePreference.recursive)
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    .disabled(secondaryEnabled)
                } label: {
                    HStack(spacing: 6) {
                        Text("When selection contains folders")
                        InfoPopover(
                            title: "Folder handling",
                            detail: secondaryEnabled
                                ? "Disabled while the second hotkey is enabled — each hotkey already picks recursive vs. non-recursive."
                                : "Controls what happens when the Finder selection contains a folder. \"Ask\" prompts each time, \"folder only\" renames just the folder itself, \"recursively\" descends into the folder and renames every file and subfolder inside it. Hidden files (.DS_Store, dotfiles) are always skipped.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }

                LabeledContent {
                    Stepper(
                        value: $recursiveWarnThreshold,
                        in: 1...10_000,
                        step: 10
                    ) {
                        Text("\(recursiveWarnThreshold) items")
                            .monospacedDigit()
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Confirm recursive rename above")
                        InfoPopover(
                            title: "Recursive batch confirmation",
                            detail: "Recursive batches larger than this item count (files + folders combined) require an extra confirmation dialog. Set higher if you regularly rename large folders and find the prompt annoying.",
                            exampleBefore: nil,
                            exampleAfter: nil
                        )
                    }
                }
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
