import SwiftUI
import Combine
import ServiceManagement

/// App-wide settings: launch-at-login, menu bar icon visibility, Dock activation.
struct GeneralSettingsPage: View {
    @ObservedObject private var dockManager = DockModeManager.shared
    @ObservedObject private var loginItem = LoginItemManager.shared
    @AppStorage(DefaultsKeys.menuBarShowIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }
                ))
                .toggleStyle(.switch)

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

    private var startupFooter: String? {
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
