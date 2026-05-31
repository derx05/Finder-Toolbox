import SwiftUI
import AppKit

/// Pages available in the Settings sidebar.
enum SettingsPage: Hashable {
    case general
    case fileRenaming
    case permissions
    case about
}

/// Root settings scene. Hosts the sidebar/detail split and forwards
/// close events to `DockModeManager` so it can drop the Dock icon
/// when running in `.settingsOnly` mode.
struct SettingsView: View {
    @State private var selection: SettingsPage? = .general

    // The split-view collapses its sidebar by default on first open; we pin
    // it open on appear and re-pin if the user collapses it. This is a known
    // workaround for the macOS 15 NavigationSplitView behaviour and is the
    // reason for commit b76f111 "Workaround Settings Sidebar".
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebar(selection: $selection)
        } detail: {
            switch selection {
            case .general, nil:
                GeneralSettingsPage()
                    .navigationTitle("")
                    .toolbar(.hidden)
            case .fileRenaming:
                FileRenamingSettingsPage()
                    .navigationTitle("")
                    .toolbar(.hidden)
            case .permissions:
                PermissionsSettingsPage()
                    .navigationTitle("")
                    .toolbar(.hidden)
            case .about:
                AboutPage()
                    .navigationTitle("")
                    .toolbar(.hidden)
            }
        }
        .navigationSplitViewStyle(.prominentDetail)
        // ~40% wider/taller than the original 620×400 — the Permissions
        // and PDF settings pages are dense enough that the original
        // minimum forced a lot of scrolling.
        .frame(minWidth: 870, minHeight: 560)
        .onAppear { columnVisibility = .all }
        .onChange(of: columnVisibility) { columnVisibility = .all }
        .background(ResizableWindowAccessor())
        .onDisappear {
            DockModeManager.shared.settingsDidClose()
        }
    }
}

/// Restores the `.resizable` style mask that SwiftUI's Settings scene strips.
private struct ResizableWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.styleMask.insert(.resizable)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Left-hand navigation list. Pinned to a fixed width — the detail pane
/// carries all the dynamic content.
private struct SettingsSidebar: View {
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

            Section("System") {
                NavigationLink(value: SettingsPage.permissions) {
                    Label("Permissions", systemImage: "lock.shield")
                }
            }

            Section("Other") {
                NavigationLink(value: SettingsPage.about) {
                    Label("About", systemImage: "info.circle")
                }
            }
        }
        .navigationTitle("Finder Toolbox")
        .navigationSplitViewColumnWidth(min: 160, ideal: 160, max: 160)
    }
}
