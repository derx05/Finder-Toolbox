import SwiftUI
import Combine
import Carbon
import ServiceManagement

/// App-wide settings: launch-at-login, menu bar icon visibility, Dock
/// activation, and the shared hotkey prefix with an overview of every
/// shortcut the app claims.
struct GeneralSettingsPage: View {
    @ObservedObject private var dockManager = DockModeManager.shared
    @ObservedObject private var loginItem = LoginItemManager.shared
    @ObservedObject private var hotkeys = HotkeyManager.shared
    @AppStorage(DefaultsKeys.menuBarShowIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                LabeledContent("Shortcut prefix") {
                    PrefixModifierPicker(hotkeys: hotkeys)
                }

                Text("Every Finder Toolbox shortcut is this prefix plus a key. The keys are set on each feature's page; ⇧ can be part of a key. macOS supports only these modifier keys for global shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if activeFeatures.isEmpty {
                    Text("No shortcuts are currently enabled. Enable them on the File Renaming and Insert Date pages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(activeFeatures, id: \.self) { feature in
                        LabeledContent(feature.displayName) {
                            Text(hotkeys.shortcutLabel(for: feature))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                if !hotkeys.duplicateKeyFeatures.isEmpty {
                    Text("Two shortcuts share the same key: \(duplicateNames). Change one of them on its feature page.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Startup") {
                Toggle("Start at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .disabled(loginItemUnavailable)

                if let message = startupFooter {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(loginItem.lastError == nil ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Menu bar icon") {
                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                    .toggleStyle(.switch)

                if !showMenuBarIcon {
                    Text("When hidden, re-launch the app via Spotlight or the Applications folder to open Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Dock icon") {
                Picker(selection: $dockManager.mode) {
                    ForEach(DockMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(dockManager.mode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    /// Only features whose shortcut is actually registered appear in the
    /// overview — disabled ones would just be noise; their keys are still
    /// configurable (and duplicate-checked) on their feature pages.
    private var activeFeatures: [HotkeyFeature] {
        HotkeyFeature.allCases.filter { hotkeys.isActive($0) }
    }

    private var duplicateNames: String {
        HotkeyFeature.allCases
            .filter { hotkeys.duplicateKeyFeatures.contains($0) }
            .map(\.displayName)
            .joined(separator: ", ")
    }

    private var loginItemUnavailable: Bool {
        BuildConfiguration.isDebug || loginItem.status == .notFound
    }

    private var startupFooter: String? {
        if BuildConfiguration.isDebug {
            return "Start at Login is not available in debug builds."
        }
        if let error = loginItem.lastError {
            return error
        }
        switch loginItem.status {
        case .requiresApproval:
            return "Approval needed in System Settings → General → Login Items."
        case .notFound:
            return "Move Finder Toolbox into the Applications folder to enable Start at Login."
        case .enabled, .notRegistered:
            return nil
        @unknown default:
            return nil
        }
    }
}

/// Toggle-button row for the shared modifier prefix. `HotkeyManager.setPrefix`
/// rejects a prefix without at least one non-⇧ modifier; because the manager
/// is the source of truth (`@ObservedObject`), a rejected toggle simply snaps
/// back instead of desyncing the UI.
private struct PrefixModifierPicker: View {
    @ObservedObject var hotkeys: HotkeyManager

    private static let modifiers: [(symbol: String, name: String, mask: UInt32)] = [
        ("⌃", "Control", UInt32(controlKey)),
        ("⌥", "Option",  UInt32(optionKey)),
        ("⇧", "Shift",   UInt32(shiftKey)),
        ("⌘", "Command", UInt32(cmdKey)),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Self.modifiers, id: \.mask) { modifier in
                Toggle(modifier.symbol, isOn: binding(for: modifier.mask))
                    .toggleStyle(.button)
                    .help(modifier.name)
            }
        }
    }

    private func binding(for mask: UInt32) -> Binding<Bool> {
        Binding(
            get: { hotkeys.prefixModifiers & mask != 0 },
            set: { _ in
                HotkeyManager.shared.setPrefix(carbonModifiers: hotkeys.prefixModifiers ^ mask)
            }
        )
    }
}
