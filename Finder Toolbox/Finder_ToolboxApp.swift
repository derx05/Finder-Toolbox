import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force DockModeManager to initialize so it applies the correct
        // activation policy (e.g. .regular for "Always visible") at launch.
        _ = DockModeManager.shared
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let manager = DockModeManager.shared
        if manager.mode == .normal || manager.isExplicitQuit {
            return .terminateNow
        }
        sender.windows.filter(\.isVisible).forEach { $0.close() }
        return .terminateCancel
    }

    // Dock-icon click or Spotlight relaunch while already running → open Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Fires when the user switches to the app (Cmd+Tab, dock click, etc.).
        // Only open Settings if no window is already visible — avoids interrupting
        // a session the user is already in.
        guard !NSApp.windows.contains(where: { $0.isVisible }) else { return }
        openSettings()
    }

    private func openSettings() {
        MainActor.assumeIsolated {
            DockModeManager.shared.willOpenSettings()
            NSApp.activate(ignoringOtherApps: true)
            AppController.shared.openSettingsAction?()
        }
    }
}

@main
struct FinderToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = AppController.shared
    @AppStorage("menuBar.showIcon") private var showMenuBarIcon = true

    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "menubar_icon") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        // Zero-size hidden window that stays alive all session.
        // Declared first so it can call openSettings() on the Settings scene below.
        Window("", id: "settings-proxy") {
            SettingsProxyView()
        }
        .defaultSize(width: 0, height: 0)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        MenuBarExtra(isInserted: .init(get: { showMenuBarIcon }, set: { _ in })) {
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

// MARK: - Settings proxy

// Invisible zero-size window that launches at startup and stays alive.
// Provides the SwiftUI context needed to call openSettings() from AppDelegate
// without the "Please use SettingsLink" warning.
private struct SettingsProxyView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppController.shared.openSettingsAction = { openSettings() }
                // Order out immediately — the scene stays alive but the window
                // is invisible for the rest of the session.
                DispatchQueue.main.async {
                    NSApp.windows
                        .first { $0.identifier?.rawValue == "settings-proxy" }?
                        .orderOut(nil)
                }
            }
    }
}

// MARK: - AppController

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    // Populated by SwiftUI views that have @Environment(\.openSettings).
    // AppDelegate uses this to open Settings without the sendAction warning.
    var openSettingsAction: (() -> Void)?

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
