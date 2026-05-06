import SwiftUI

struct SettingsView: View {
    @StateObject private var permissions = PermissionsManager.shared
    @State private var isRecordingHotkey = false
    @State private var hotkeyLabel = HotkeyManager.shared.currentShortcutLabel
    @AppStorage("cleanup.trimStemWhitespace") private var trimStemWhitespace = false

    var body: some View {
        Form {
            Section("Rename") {
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
                Toggle("Remove space before extension", isOn: $trimStemWhitespace)
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
        .frame(width: 380)
        .padding(.vertical)
        .task {
            await permissions.checkPermission()
        }
    }
}

private struct HotkeyRow: View {
    let label: String
    @Binding var isRecording: Bool
    let onNewShortcut: (UInt16, NSEvent.ModifierFlags) -> Void

    var body: some View {
        LabeledContent("Global Shortcut") {
            HotkeyRecorderView(
                displayLabel: isRecording ? "Press keys…" : label,
                isRecording: isRecording,
                onTap: { isRecording = true },
                onNewShortcut: { keyCode, mods in
                    isRecording = false
                    onNewShortcut(keyCode, mods)
                },
                onCancel: { isRecording = false }
            )
        }
    }
}

// Tap to start recording, press a key combo to commit, Esc to cancel.
private struct HotkeyRecorderView: NSViewRepresentable {
    let displayLabel: String
    let isRecording: Bool
    let onTap: () -> Void
    let onNewShortcut: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.tapped)
        context.coordinator.view = button
        context.coordinator.onNewShortcut = onNewShortcut
        context.coordinator.onCancel = onCancel
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = displayLabel
        button.isRecording = isRecording
        context.coordinator.onNewShortcut = onNewShortcut
        context.coordinator.onCancel = onCancel
        if isRecording {
            button.window?.makeFirstResponder(button)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        weak var view: RecorderButton?
        var onTap: () -> Void
        var onNewShortcut: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        @objc func tapped() { onTap() }
    }

    final class RecorderButton: NSButton {
        var isRecording = false

        override var acceptsFirstResponder: Bool { isRecording }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }

            if event.keyCode == 53 {  // kVK_Escape = 53
                (target as? Coordinator)?.onCancel?()
                return
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return }

            (target as? Coordinator)?.onNewShortcut?(event.keyCode, mods)
        }
    }
}
