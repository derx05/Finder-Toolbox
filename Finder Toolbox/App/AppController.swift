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

    /// File count above which a recursive batch demands explicit confirmation.
    /// Tunable from settings (`DefaultsKeys.recursiveWarnThreshold`); the
    /// default of 50 catches "I picked the wrong folder" mistakes without
    /// nagging on normal-sized batches.
    static let defaultRecursiveWarnThreshold = 50

    private init() {
        HotkeyManager.shared.onFire = { [weak self] in
            Task { @MainActor in await self?.performRename() }
        }
        HotkeyManager.shared.onSecondaryFire = { [weak self] in
            Task { @MainActor in await self?.performRename(forcedFolderMode: .recursive) }
        }
        HotkeyManager.shared.setup()
    }

    /// Run a rename batch against Finder's current selection.
    ///
    /// - Parameter forcedFolderMode: when non-nil, bypass the user's folder
    ///   preference and the ask-prompt. Used by the secondary "always
    ///   recursive" hotkey and could be wired from a menu item.
    func performRename(forcedFolderMode: FolderMode? = nil) async {
        guard !isRenaming else { return }
        isRenaming = true
        defer { isRenaming = false }

        // Plan first so we can prompt with accurate counts before touching anything.
        let initialMode: FolderMode = forcedFolderMode ?? .flat
        let initialPlan: RenameExecutor.Plan
        do {
            initialPlan = try await executor.plan(folderMode: initialMode)
        } catch FinderBridgeError.noSelection {
            return
        } catch FinderBridgeError.automationDenied {
            PermissionsManager.shared.markDenied()
            SummaryDialog.showPermissionDenied()
            return
        } catch {
            SummaryDialog.showIfNeeded(BatchSummary(outcomes: [
                .failed(URL(fileURLWithPath: "/"), error: error.localizedDescription)
            ]))
            return
        }

        // Resolve folder mode for this batch.
        let resolvedMode: FolderMode
        if let forced = forcedFolderMode {
            resolvedMode = forced
        } else if HotkeyManager.shared.secondaryEnabled {
            // Two-hotkey mode: primary is fixed to non-recursive; the user
            // opted out of prompts by enabling the dedicated recursive hotkey.
            resolvedMode = .flat
        } else if initialPlan.folderCount == 0 {
            resolvedMode = .flat  // No folders in selection → choice doesn't matter.
        } else {
            switch FolderModePreference.current() {
            case .flat:
                resolvedMode = .flat
            case .recursive:
                resolvedMode = .recursive
            case .ask:
                let otherCount = initialPlan.renames.count - initialPlan.folderCount
                switch FolderModeDialog.askFolderMode(
                    folderCount: initialPlan.folderCount,
                    otherCount: otherCount
                ) {
                case .flat:      resolvedMode = .flat
                case .recursive: resolvedMode = .recursive
                case .cancel:    return
                }
            }
        }

        // Replan if recursion was chosen — the initial plan is flat-only.
        let plan: RenameExecutor.Plan
        if resolvedMode == .recursive && initialMode != .recursive {
            do {
                plan = try await executor.plan(folderMode: .recursive)
            } catch {
                SummaryDialog.showIfNeeded(BatchSummary(outcomes: [
                    .failed(URL(fileURLWithPath: "/"), error: error.localizedDescription)
                ]))
                return
            }
        } else {
            plan = initialPlan
        }

        // Threshold confirmation for recursive batches.
        if resolvedMode == .recursive {
            let threshold = recursiveWarnThreshold
            if plan.fileCount > threshold {
                guard FolderModeDialog.confirmLargeBatch(
                    fileCount: plan.fileCount,
                    folderCount: plan.folderCount
                ) else { return }
            }
        }

        if plan.isEmpty { return }

        let progressTask = Task { @MainActor [weak self] in
            try await Task.sleep(for: Self.progressDelay)
            let controller = ProgressWindowController()
            controller.show(fileCount: plan.renames.count)
            self?.progressController = controller
        }

        let summary = await executor.execute(plan: plan)

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

    // MARK: - Private

    private var recursiveWarnThreshold: Int {
        let stored = UserDefaults.standard.integer(forKey: DefaultsKeys.recursiveWarnThreshold)
        return stored > 0 ? stored : Self.defaultRecursiveWarnThreshold
    }
}
