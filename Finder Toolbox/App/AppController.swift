import Foundation
import AppKit
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

    /// Item count (files + folders) above which a recursive batch demands
    /// explicit confirmation. Tunable from settings
    /// (`DefaultsKeys.recursiveWarnThreshold`); the default of 50 catches
    /// "I picked the wrong folder" mistakes without nagging on normal batches.
    static let defaultRecursiveWarnThreshold = 50

    private init() {
        // Must run before HotkeyManager.setup(): the released copy's global
        // hotkey registration conflicts with the debug build's, which wedges
        // the released app's main thread. AppDelegate.applicationDidFinishLaunching
        // is too late — this init fires during App-struct StateObject creation,
        // before any delegate method.
        #if DEBUG
        Self.terminateOtherInstances()
        #endif

        HotkeyManager.shared.onFire = { [weak self] in
            Task { @MainActor in await self?.performRename() }
        }
        HotkeyManager.shared.onSecondaryFire = { [weak self] in
            Task { @MainActor in await self?.performRename(forcedFolderMode: .recursive) }
        }
        HotkeyManager.shared.setup()

        #if DEBUG
        // Issue #29 drag-time drop targets — DEBUG-only while in development.
        // No settings yet; always-on when running a debug build.
        DropTargetsCoordinator.shared.start()
        #endif
    }

    #if DEBUG
    /// Kill any already-running copy of Finder Toolbox so the debug build
    /// doesn't fight it for the global hotkey. Uses `forceTerminate()` rather
    /// than `terminate()` because the released copy may already be wedged by
    /// the hotkey-registration conflict and would no longer respond to the
    /// polite quit AppleEvent.
    private static func terminateOtherInstances() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        for app in others {
            app.forceTerminate()
        }
        // Give the OS a moment to reclaim the hotkey registration before
        // HotkeyManager.setup() tries to claim it.
        let deadline = Date().addingTimeInterval(2)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
    #endif

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

        // Threshold confirmation for recursive batches. The threshold applies
        // to the total item count — folders count too, since a folder rename
        // is just as impactful as a file rename (and a tree of empty folders
        // would otherwise sail past the check).
        if resolvedMode == .recursive, recursiveWarnEnabled {
            let totalItems = plan.fileCount + plan.folderCount
            if totalItems > recursiveWarnThreshold {
                guard FolderModeDialog.confirmLargeBatch(
                    fileCount: plan.fileCount,
                    folderCount: plan.folderCount
                ) else { return }
            }
        }

        if plan.isEmpty { return }

        // Resolve any PDF date ambiguities the planner flagged. Cancel-batch
        // from the dialog aborts the whole rename.
        let finalPlan: RenameExecutor.Plan
        if plan.pdfDecisions.isEmpty {
            finalPlan = plan
        } else {
            guard let resolutions = resolvePdfDecisions(plan.pdfDecisions) else { return }
            finalPlan = await executor.applyPdfResolutions(plan: plan, resolutions: resolutions)
        }

        if finalPlan.isEmpty { return }

        let progressTask = Task { @MainActor [weak self] in
            try await Task.sleep(for: Self.progressDelay)
            let controller = ProgressWindowController()
            controller.show(fileCount: finalPlan.renames.count)
            self?.progressController = controller
        }

        let summary = await executor.execute(plan: finalPlan)

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

    private var recursiveWarnEnabled: Bool {
        // Defaults register() seeds `true`; reading directly so the rename
        // controller doesn't need a settings round-trip.
        UserDefaults.standard.bool(forKey: DefaultsKeys.recursiveWarnEnabled)
    }

    /// Walks the planner's pending PDF decisions and asks the user which
    /// candidate to use, one alert per decision (with an "apply to remaining"
    /// shortcut). Returns the map of overrides for `applyPdfResolutions`, or
    /// `nil` if the user cancelled the batch.
    ///
    /// Decisions of kind `.conflict` and `.noDate` are presented separately
    /// because the "apply to remaining" sticky-disposition only makes sense
    /// within the same kind: choosing "use metadata" for a conflict shouldn't
    /// auto-pick anything for a different no-date prompt.
    private func resolvePdfDecisions(_ decisions: [PdfPendingDecision]) -> [URL: DateComponents]? {
        var resolutions: [URL: DateComponents] = [:]

        let conflicts = decisions.filter { $0.kind == .conflict }
        let noDates   = decisions.filter { $0.kind == .noDate }

        var stickyConflict: PdfConflictDialog.Disposition?
        for (i, decision) in conflicts.enumerated() {
            let disposition: PdfConflictDialog.Disposition
            if let sticky = stickyConflict {
                disposition = sticky
            } else {
                let response = PdfConflictDialog.askConflict(
                    decision: decision,
                    index: i + 1,
                    total: conflicts.count
                )
                guard let chosen = response.disposition else { return nil }
                disposition = chosen
                if response.applyToRemaining { stickyConflict = chosen }
            }
            if let date = pickDate(for: disposition, from: decision) {
                resolutions[decision.originalURL] = date
            }
        }

        var stickyNoDate: PdfConflictDialog.Disposition?
        for (i, decision) in noDates.enumerated() {
            let disposition: PdfConflictDialog.Disposition
            if let sticky = stickyNoDate {
                disposition = sticky
            } else {
                let response = PdfConflictDialog.askNoDate(
                    decision: decision,
                    index: i + 1,
                    total: noDates.count
                )
                guard let chosen = response.disposition else { return nil }
                disposition = chosen
                if response.applyToRemaining { stickyNoDate = chosen }
            }
            if let date = pickDate(for: disposition, from: decision) {
                resolutions[decision.originalURL] = date
            }
        }

        return resolutions
    }

    private func pickDate(
        for disposition: PdfConflictDialog.Disposition,
        from decision: PdfPendingDecision
    ) -> DateComponents? {
        switch disposition {
        case .heuristic: return decision.heuristic
        case .metadata:  return decision.metadata
        case .today:     return FilenameBuilder.todayComponents()
        }
    }
}
