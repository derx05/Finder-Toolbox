import SwiftUI
import Combine

/// Contents of the menu bar dropdown.
///
/// The menu intentionally stays minimal: the hotkey is the primary surface,
/// this menu is for discoverability and the occasional Undo.
struct MenuBarContentView: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            Button(controller.isRenaming ? "Renaming…" : "Rename Selection") {
                Task { await controller.performRename() }
            }
            .disabled(controller.isRenaming)

            if !controller.lastBatch.isEmpty {
                let count = controller.lastBatch.count
                Button("Undo Last Rename (\(count) \(count == 1 ? "file" : "files"))") {
                    Task { await controller.undoLastRename() }
                }
                .disabled(controller.isRenaming)
            }

            Divider()

            Button("Settings…") {
                DockModeManager.shared.willOpenSettings()
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            Button("Quit Finder Toolbox") {
                DockModeManager.shared.explicitQuit()
            }
        }
    }
}
