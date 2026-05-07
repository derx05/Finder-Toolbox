import SwiftUI

// MARK: - Root

private enum SettingsPage: Hashable {
    case general
    case fileRenaming
    case about
}

struct SettingsView: View {
    @State private var selection: SettingsPage? = .general

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                //.toolbar(removing: .sidebarToggle)
        } detail: {
            switch selection {
            case .general, nil:
                GeneralSettingsView()
            case .fileRenaming:
                FileRenamingSettingsView()
            case .about:
                AboutView()
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var selection: SettingsPage?

    var body: some View {
        List(selection: $selection) {
            NavigationLink(value: SettingsPage.general) {
                Label("General", systemImage: "gearshape")
            }

            Section("Features") {
                NavigationLink(value: SettingsPage.fileRenaming) {
                    Label("File Renaming", systemImage: "pencil.and.outline")
                }
            }

            Section("Other") {
                NavigationLink(value: SettingsPage.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Finder Toolbox")
        .navigationSplitViewColumnWidth(160)
    }
}

// MARK: - General page

private struct GeneralSettingsView: View {
    var body: some View {
        Form {
            // Placeholder — general settings go here in future
        }
        .formStyle(.grouped)
        .overlay {
            if true {
                Text("No general settings yet.")
                    .foregroundStyle(.tertiary)
                    .font(.subheadline)
            }
        }
    }
}

// MARK: - About page

private struct AboutView: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)

            Text("Finder Toolbox")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Version \(version) (\(build))")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - File Renaming settings page

private struct FileRenamingSettingsView: View {
    @StateObject private var permissions = PermissionsManager.shared
    @State private var isRecordingHotkey = false
    @State private var hotkeyLabel = HotkeyManager.shared.currentShortcutLabel
    @AppStorage("cleanup.trimStemWhitespace") private var trimStemWhitespace = false
    @AppStorage("eml.useDateHeader") private var emlUseDateHeader = true

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

// MARK: - Info popover

private struct InfoPopover: View {
    let title: String
    let detail: String
    let exampleBefore: String
    let exampleAfter: String

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 8) {
                    Text(exampleBefore)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    Text(exampleAfter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.subheadline, design: .monospaced))
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}

// MARK: - Hotkey recorder

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
            .frame(width: 140)
        }
    }
}

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

            if event.keyCode == 53 {  // kVK_Escape
                (target as? Coordinator)?.onCancel?()
                return
            }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return }

            (target as? Coordinator)?.onNewShortcut?(event.keyCode, mods)
        }
    }
}
