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
        .windowResizability(.contentMinSize)
    }
}

// MARK: - AppController

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    @Published private(set) var isRenaming = false
    @Published private(set) var lastBatch: [RenameRecord] = []

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

        lastBatch = summary.outcomes.compactMap { outcome in
            if case .renamed(let from, let to) = outcome {
                return RenameRecord(renamedURL: to, originalName: from.lastPathComponent)
            }
            return nil
        }

        SummaryDialog.showIfNeeded(summary)
    }

    func undoLastRename() async {
        guard !isRenaming, !lastBatch.isEmpty else { return }
        isRenaming = true
        defer { isRenaming = false }
        let records = lastBatch
        lastBatch = []
        let summary = await executor.reverseRename(records)
        SummaryDialog.showIfNeeded(summary)
    }

}

// MARK: - MenuBarContentView

struct MenuBarContentView: View {
    @EnvironmentObject var controller: AppController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
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
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("Quit Finder Toolbox") {
            NSApplication.shared.terminate(nil)
        }
    }
}
