import Foundation
import AppKit
import Combine

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    enum Status {
        case unknown, authorized, denied
    }

    @Published private(set) var finderAutomationStatus: Status = .unknown

    /// Mirrors `hasFullDiskAccess()` as a publishable property so SwiftUI
    /// views (the Permissions settings page) can observe live changes
    /// after the user toggles FDA in System Settings.
    @Published private(set) var fullDiskAccessStatus: Status = .unknown

    func markDenied() { finderAutomationStatus = .denied }

    private init() {}

    /// Re-probes every permission and publishes the result. Called by the
    /// Permissions settings page when it appears and when the app becomes
    /// active again (covering the System Settings round-trip).
    func refreshAll() async {
        // Always refresh — overrides the .unknown short-circuit in
        // checkPermission() so a previously-denied Automation grant gets
        // re-evaluated after the user opens Settings and toggles it.
        finderAutomationStatus = .unknown
        await checkPermission()
        fullDiskAccessStatus = hasFullDiskAccess() ? .authorized : .denied
    }

    // Runs a harmless script to probe permission state (and trigger the system prompt on first use).
    // Call from a background Task; NSAppleScript is synchronous.
    func checkPermission() async {
        guard finderAutomationStatus == .unknown else { return }
        let status = await Task.detached(priority: .userInitiated) {
            let source = "tell application \"Finder\" to get version"
            guard let script = NSAppleScript(source: source) else { return Status.unknown }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let info = errorInfo {
                let number = (info["NSAppleScriptErrorNumber"] as? Int) ?? 0
                return number == -1743 ? Status.denied : Status.unknown
            }
            return Status.authorized
        }.value

        finderAutomationStatus = status
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Probes Full Disk Access by attempting to access a TCC-gated path
    /// that always exists on macOS. The `TCC.db` system database is
    /// readable only with FDA granted — `isReadableFile` answers via
    /// `access(_:_:)` without producing user-visible side effects.
    ///
    /// Returns `false` if FDA isn't granted (or the probe path is somehow
    /// missing); callers should fall back to the "request FDA" UX rather
    /// than attempting the operation and absorbing a confusing TCC prompt
    /// directed at the wrong subject.
    func hasFullDiskAccess() -> Bool {
        FileManager.default.isReadableFile(
            atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
        )
    }

    /// Standardized TCC-gated folders on this system. Used by the
    /// drop-targets feature to know, ahead of a move attempt, whether
    /// the destination requires Full Disk Access (or per-folder Files &
    /// Folders TCC). The list isn't exhaustive — iCloud Drive paths and
    /// some external volumes are also gated — but it covers the
    /// folders Finder normally shows in its sidebar.
    func isTCCGatedDestination(_ folder: URL) -> Bool {
        let target = folder.standardizedFileURL.path
        let home = NSHomeDirectory()
        let gated: [String] = [
            home,
            "\(home)/Desktop",
            "\(home)/Documents",
            "\(home)/Downloads",
            "\(home)/Movies",
            "\(home)/Music",
            "\(home)/Pictures",
            "\(home)/Library",
        ]
        return gated.contains(target)
    }

    /// Opens System Settings → Privacy & Security → Full Disk Access.
    /// Needed for the drop-targets feature: a file *move* via Apple Events
    /// to Finder is gated by TCC on the destination path, and TCC checks
    /// the AppleScript caller (us) rather than Finder. Cross-folder moves
    /// into TCC-protected locations (~/, ~/Desktop, ~/Documents,
    /// ~/Downloads, etc.) therefore fail with "you don't have the
    /// necessary permission" unless Finder Toolbox has Full Disk Access.
    /// In-place renames (the hotkey path) are unaffected.
    func openSystemSettingsForFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
