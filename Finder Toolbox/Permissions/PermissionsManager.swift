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

    func markDenied() { finderAutomationStatus = .denied }

    private init() {}

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
