import SwiftUI
import Combine

/// App-wide settings: menu bar icon visibility and Dock activation policy.
struct GeneralSettingsPage: View {
    @ObservedObject private var dockManager = DockModeManager.shared
    @AppStorage(DefaultsKeys.menuBarShowIcon) private var showMenuBarIcon = true

    var body: some View {
        Form {
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
}
