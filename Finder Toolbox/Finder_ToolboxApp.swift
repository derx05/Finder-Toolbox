import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Never quit automatically when the last window closes — the app lives in
    // the menu bar regardless of mode.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // In headless/settingsOnly modes, Cmd+Q and the system Quit menu item
    // close open windows but keep the app running. Only an explicit call to
    // DockModeManager.explicitQuit() (our "Quit" buttons) terminates.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = DockModeManager.shared
        if manager.mode == .normal || manager.isExplicitQuit {
            return .terminateNow
        }
        sender.windows.filter(\.isVisible).forEach { $0.close() }
        return .terminateCancel
    }
}

@main
struct FinderToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = AppController.shared

    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "menubar_icon") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(controller)
        } label: {
            Image(nsImage: Self.menuBarIcon)
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
            DockModeManager.shared.willOpenSettings()
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("Quit Finder Toolbox") {
            DockModeManager.shared.explicitQuit()
        }
    }
}
