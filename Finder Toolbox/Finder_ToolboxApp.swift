import SwiftUI
import Combine

@main
struct FinderToolboxApp: App {
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra("Finder Toolbox", systemImage: "wand.and.stars") {
            MenuBarContentView()
                .environmentObject(controller)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - AppController

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var isRenaming = false

    private let executor = RenameExecutor()
    private var progressController: ProgressWindowController?

    private init() {
        HotkeyManager.shared.onFire = { [weak self] in
            Task { @MainActor in await self?.performRename() }
        }
        HotkeyManager.shared.setup()
    }

    func performRename() async {
        guard !isRenaming else { return }
        isRenaming = true
        defer { isRenaming = false }

        // Adaptive progress: reveal panel only if rename takes > 2 s
        let progressTask = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(2))
            let controller = ProgressWindowController()
            controller.show(fileCount: 0)
            self?.progressController = controller
        }

        let summary = await executor.run()

        progressTask.cancel()
        progressController?.hide()
        progressController = nil

        if PermissionsManager.shared.finderAutomationStatus == .denied {
            SummaryDialog.showPermissionDenied()
            return
        }

        SummaryDialog.showIfNeeded(summary)
    }
}

// MARK: - MenuBarContentView

struct MenuBarContentView: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Button(controller.isRenaming ? "Renaming…" : "Rename Selection") {
            Task { await controller.performRename() }
        }
        .disabled(controller.isRenaming)

        Divider()

        SettingsLink()

        Divider()

        Button("Quit Finder Toolbox") {
            NSApplication.shared.terminate(nil)
        }
    }
}
