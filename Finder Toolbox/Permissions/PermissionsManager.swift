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
}
