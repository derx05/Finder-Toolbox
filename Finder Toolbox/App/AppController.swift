import Foundation
import SwiftUI
import Combine

/// Coordinates the rename workflow that the menu bar and global hotkey both
/// trigger. Single-instance, main-actor-isolated.
///
/// Owns the `RenameExecutor` (the off-main-actor that runs AppleScript),
/// the optional progress panel, and the "last batch" history the menu uses
/// to drive its Undo entry.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    /// Populated by `SettingsProxyView` once SwiftUI has wired up
    /// `@Environment(\.openSettings)`. `AppDelegate` uses this indirection to
    /// open Settings without triggering the "Please use SettingsLink" warning.
    var openSettingsAction: (() -> Void)?

    @Published private(set) var isRenaming = false
    @Published private(set) var lastBatch: [RenameRecord] = []

    private let executor = RenameExecutor()
    private var progressController: ProgressWindowController?

    /// Delay before the progress panel appears. Short batches finish silently;
    /// longer batches get a visible "Renaming…" indicator.
    private static let progressDelay: Duration = .seconds(2)

    private init() {
        HotkeyManager.shared.onFire = { [weak self] in
            Task { @MainActor in await self?.performRename() }
        }
        HotkeyManager.shared.setup()
    }

    /// Run a rename batch against Finder's current selection.
    func performRename() async {
        guard !isRenaming else { return }
        isRenaming = true
        defer { isRenaming = false }

        // Show a progress panel only if the batch is still running after the
        // delay. The task is cancelled below if the batch finishes faster.
        let progressTask = Task { @MainActor [weak self] in
            try await Task.sleep(for: Self.progressDelay)
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

    /// Reverse the most recent batch by asking Finder to rename each file back
    /// to its original name. Apple Events keep the operation in Finder's own
    /// undo stack, so a manual Cmd-Z in Finder also works.
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
