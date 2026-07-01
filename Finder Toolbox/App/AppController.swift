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
    @Published private(set) var lastBatch: [BatchAction] = []

    private let executor = RenameExecutor()

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

        // Issue #29 drag-time drop targets. Off by default — gated by
        // the `dropTargets.enabled` user default, settable on the
        // dedicated Settings page. Observe defaults so toggling the
        // switch in Settings starts/stops the coordinator live without
        // requiring a restart.
        DropTargetsCoordinator.shared.refreshFromDefaults()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DropTargetsCoordinator.shared.refreshFromDefaults()
            }
        }
    }

    #if DEBUG
    /// Kill any already-running copy of Finder Toolbox so the debug build
    /// doesn't fight it for the global hotkey. Uses `forceTerminate()` rather
    /// than `terminate()` because the released copy may already be wedged by
    /// the hotkey-registration conflict and would no longer respond to the
    /// polite quit AppleEvent.
    private static func terminateOtherInstances() {
        // Debug and Release builds use different bundle IDs (so they can
        // hold independent Full Disk Access entries), but they still
        // conflict on global hotkey registration. Kill *both* siblings:
        // the other-config copy as well as same-config instances.
        let me = ProcessInfo.processInfo.processIdentifier
        let candidateIDs = [
            "danielammann.Finder-Toolbox",
            "danielammann.Finder-Toolbox.debug",
        ]
        let others = candidateIDs.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
        }.filter { $0.processIdentifier != me }
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
        // Use .filesAndFolders here so `initialPlan.foldersInSelection` reflects
        // every folder that *could* be renamed — the scope decision is resolved
        // below and a replan applies the final filter.
        let initialMode: FolderMode = forcedFolderMode ?? .flat
        let initialPlan: RenameExecutor.Plan
        do {
            initialPlan = try await executor.plan(folderMode: initialMode, renameFolders: .filesAndFolders)
        } catch FinderBridgeError.noSelection {
            return
        } catch FinderBridgeError.automationDenied {
            PermissionsManager.shared.markDenied()
            SummaryDialog.showPermissionDenied()
            return
        } catch {
            NotchFeedbackController.shared.showError("Rename failed", detail: error.localizedDescription)
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
        } else if initialPlan.foldersInSelection == 0 {
            resolvedMode = .flat  // No folders in selection → choice doesn't matter.
        } else {
            switch FolderModePreference.current() {
            case .flat:
                resolvedMode = .flat
            case .recursive:
                resolvedMode = .recursive
            case .ask:
                let n = initialPlan.foldersInSelection
                let prompt = n == 1 ? "1 folder in selection" : "\(n) folders in selection"
                guard let modeId = await NotchFeedbackController.shared.askChoice(
                    prompt: prompt,
                    options: [(id: "flat", label: "Files only"), (id: "recursive", label: "Recursive")]
                ) else { return }
                resolvedMode = modeId == "recursive" ? .recursive : .flat
            }
        }

        // Resolve folder rename scope (do folder *names* get renamed?). Only
        // relevant when folders are touched — for a pure file selection in
        // flat mode there is nothing to ask about.
        let resolvedScope: FolderRenameScope
        let foldersWillBeTouched = initialPlan.foldersInSelection > 0
        if !foldersWillBeTouched {
            resolvedScope = .filesAndFolders  // No folders → choice is moot.
        } else {
            switch FolderRenameScopePreference.current() {
            case .filesOnly:
                resolvedScope = .filesOnly
            case .filesAndFolders:
                resolvedScope = .filesAndFolders
            case .ask:
                guard let scopeId = await NotchFeedbackController.shared.askChoice(
                    prompt: "Rename folder names too?",
                    options: [(id: "filesOnly", label: "Files only"), (id: "filesAndFolders", label: "Files & folders")]
                ) else { return }
                resolvedScope = scopeId == "filesAndFolders" ? .filesAndFolders : .filesOnly
            }
        }

        // Replan if recursion was chosen OR scope changed from the initial
        // .filesAndFolders default — the initial plan is flat + folder-inclusive.
        let plan: RenameExecutor.Plan
        let needsReplan = (resolvedMode == .recursive && initialMode != .recursive)
            || resolvedScope == .filesOnly
        if needsReplan {
            do {
                plan = try await executor.plan(folderMode: resolvedMode, renameFolders: resolvedScope)
            } catch {
                NotchFeedbackController.shared.showError("Rename failed", detail: error.localizedDescription)
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

        if plan.isEmpty {
            NotchFeedbackController.shared.showSuccess("Nothing to rename")
            return
        }

        // Resolve any PDF date ambiguities the planner flagged. Cancel-batch
        // from the dialog aborts the whole rename.
        let finalPlan: RenameExecutor.Plan
        if plan.pdfDecisions.isEmpty {
            finalPlan = plan
        } else {
            guard let resolutions = resolvePdfDecisions(plan.pdfDecisions) else { return }
            finalPlan = await executor.applyPdfResolutions(plan: plan, resolutions: resolutions)
        }

        if finalPlan.isEmpty {
            NotchFeedbackController.shared.showSuccess("Nothing to rename")
            return
        }

        let progressTask = Task { @MainActor in
            try await Task.sleep(for: Self.progressDelay)
            NotchFeedbackController.shared.showProgress("Renaming…")
        }

        let summary = await executor.execute(plan: finalPlan)

        progressTask.cancel()

        if PermissionsManager.shared.finderAutomationStatus == .denied {
            NotchFeedbackController.shared.dismiss()
            SummaryDialog.showPermissionDenied()
            return
        }

        lastBatch = summary.outcomes.compactMap { outcome in
            if case .renamed(let from, let to) = outcome {
                return BatchAction.rename(at: to, restoreName: from.lastPathComponent)
            }
            return nil
        }

        showRenameFeedback(summary)
    }

    private func showRenameFeedback(_ summary: BatchSummary) {
        let renamed = summary.renamedCount
        let failed = summary.failed
        let skipped = summary.skipped

        if !failed.isEmpty, renamed == 0, skipped.isEmpty {
            let message = failed.count == 1 ? "Rename failed" : "\(failed.count) renames failed"
            let detail = failed.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
            NotchFeedbackController.shared.showError(message, detail: detail)
        } else if !failed.isEmpty {
            var parts: [String] = []
            if renamed > 0 { parts.append("\(renamed) renamed") }
            parts.append("\(failed.count) failed")
            let detail = failed.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
            NotchFeedbackController.shared.showWarning(parts.joined(separator: " · "), detail: detail)
        } else if renamed > 0 {
            var message = "\(renamed) file\(renamed == 1 ? "" : "s") renamed"
            if !skipped.isEmpty { message += " · \(skipped.count) already up to date" }
            NotchFeedbackController.shared.showSuccess(message)
        } else {
            let message = skipped.count == 1 ? "Already up to date" : "All files already up to date"
            NotchFeedbackController.shared.showSuccess(message)
        }
    }

    /// Drop-target entry point. Routes drag-and-drop drops onto a Finder-window
    /// overlay through the same naming + Finder Apple Events plumbing the
    /// hotkey path uses, just with an explicit destination folder instead
    /// of an in-place rename.
    @discardableResult
    func performDrop(urls: [URL], into targetFolder: URL, operation: DropOperation) async -> DropOutcome {
        guard !urls.isEmpty, !isRenaming else {
            DebugLog.log("perform-drop",
                         "skipped — empty=\(urls.isEmpty) busy=\(isRenaming)",
                         level: .warning)
            return .cancelled
        }
        isRenaming = true
        defer { isRenaming = false }

        DebugLog.log("perform-drop",
                     "start — \(urls.count) item(s) op=\(operation) → \(targetFolder.path)")

        // Proactive TCC check: if the target folder is TCC-gated and we
        // don't have Full Disk Access, the move via Finder Apple Events
        // will fail after macOS shows a misleading "Finder wants to make
        // changes" prompt (the OS attributes the request to Finder
        // visually but checks our TCC context). Short-circuit before
        // touching Finder so the user sees one clean dialog with a deep
        // link instead of a confusing two-prompt loop.
        if PermissionsManager.shared.isTCCGatedDestination(targetFolder),
           !PermissionsManager.shared.hasFullDiskAccess() {
            DebugLog.log("perform-drop",
                         "TCC-gated destination + no FDA — showing recovery dialog",
                         level: .error)
            DropResultToast.showIfEnabled(targetFolder: targetFolder, operation: operation,
                                          inputCount: urls.count, renamed: 0,
                                          failed: [(targetFolder, "Full Disk Access required")],
                                          skipped: 0)
            SummaryDialog.showFullDiskAccessRequired()
            return .failed
        }

        // Same proactive TCC check, but for sources living inside another
        // app's sandbox container (Mail attachments under
        // `~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/`
        // are the common case). Without FDA the Finder duplicate verb
        // fails with "operation can't be completed" and our FileManager
        // fallback hits EPERM at `open(2)` — neither surfaces the actual
        // remedy. Short-circuit with the same recovery dialog.
        if let gatedSource = urls.first(where: { PermissionsManager.shared.isTCCGatedSource($0) }),
           !PermissionsManager.shared.hasFullDiskAccess() {
            DebugLog.log("perform-drop",
                         "TCC-gated source (\(gatedSource.path)) + no FDA — showing recovery dialog",
                         level: .error)
            DropResultToast.showIfEnabled(targetFolder: targetFolder, operation: operation,
                                          inputCount: urls.count, renamed: 0,
                                          failed: [(gatedSource, "Full Disk Access required")],
                                          skipped: 0)
            SummaryDialog.showFullDiskAccessRequired()
            return .failed
        }

        // Resolve folder-mode + folder-scope from the file-renamer prefs
        // when the drop contains any folders. Same prefs and same "ask"
        // dialogs the hotkey path uses, so dropping a folder behaves the
        // same way as selecting one and pressing the hotkey. The
        // two-hotkey setting is intentionally ignored here — drops have
        // no secondary hotkey to switch behavior with.
        let folderCount = urls.reduce(into: 0) { count, url in
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                count += 1
            }
        }
        let otherCount = urls.count - folderCount
        let resolvedFolderMode: FolderMode
        let resolvedRenameScope: FolderRenameScope
        if folderCount == 0 {
            resolvedFolderMode = .flat
            resolvedRenameScope = .filesAndFolders
        } else {
            switch FolderModePreference.current() {
            case .flat:
                resolvedFolderMode = .flat
            case .recursive:
                resolvedFolderMode = .recursive
            case .ask:
                switch FolderModeDialog.askFolderMode(folderCount: folderCount, otherCount: otherCount) {
                case .flat:      resolvedFolderMode = .flat
                case .recursive: resolvedFolderMode = .recursive
                case .cancel:    return .cancelled
                }
            }
            switch FolderRenameScopePreference.current() {
            case .filesOnly:
                resolvedRenameScope = .filesOnly
            case .filesAndFolders:
                resolvedRenameScope = .filesAndFolders
            case .ask:
                switch FolderModeDialog.askFolderRenameScope(folderCount: folderCount, fileCount: otherCount) {
                case .filesOnly:       resolvedRenameScope = .filesOnly
                case .filesAndFolders: resolvedRenameScope = .filesAndFolders
                case .cancel:          return .cancelled
                }
            }
        }

        let dropResult = await executor.executeDrop(
            urls: urls,
            into: targetFolder,
            operation: operation,
            folderMode: resolvedFolderMode,
            renameFolders: resolvedRenameScope
        )
        let summary = dropResult.summary

        DebugLog.log("perform-drop",
                     "executor done — renamed=\(summary.renamedCount) skipped=\(summary.skipped.count) failed=\(summary.failed.count)",
                     level: summary.failed.isEmpty ? .info : .error)
        for (url, err) in summary.failed {
            DebugLog.log("perform-drop", "  failed: \(url.lastPathComponent) — \(err)", level: .error)
        }

        DropResultToast.showIfEnabled(targetFolder: targetFolder, operation: operation,
                                      inputCount: urls.count,
                                      renamed: summary.renamedCount,
                                      failed: summary.failed,
                                      skipped: summary.skipped.count)

        if PermissionsManager.shared.finderAutomationStatus == .denied {
            SummaryDialog.showPermissionDenied()
            return .failed
        }

        // Detect the FDA-on-destination denial. Surfaced via the failure
        // message string because RenameOutcome.failed only carries a
        // String, and the localized message starts with a sentinel
        // produced by FinderBridgeError.destinationNotPermitted. Show the
        // dedicated dialog (with the System Settings deep link) instead
        // of the generic summary; if the move couldn't even reach Finder,
        // the user needs the recovery path, not a per-file error list.
        let fdaDenied = summary.failed.contains { _, error in
            error.contains("Full Disk Access")
        }
        if fdaDenied {
            SummaryDialog.showFullDiskAccessRequired()
            return .failed
        }

        lastBatch = dropResult.undoActions

        SummaryDialog.showIfNeeded(summary)
        return .completed(hadFailures: !summary.failed.isEmpty)
    }

    /// Reverse the most recent batch by asking Finder to rename each file back
    /// to its original name. Apple Events keep the operation in Finder's own
    /// undo stack, so a manual Cmd-Z in Finder also works.
    func undoLastRename() async {
        guard !isRenaming, !lastBatch.isEmpty else { return }
        isRenaming = true
        defer { isRenaming = false }

        let actions = lastBatch
        lastBatch = []
        let summary = await executor.reverseLastBatch(actions)
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
