import AppKit
import Combine
import OSLog
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the General settings toggle has something to
/// bind against. Source of truth is launchd — we don't mirror state into
/// `UserDefaults`, otherwise the toggle would drift from reality whenever the
/// user changes Login Items in System Settings.
@MainActor
final class LoginItemManager: ObservableObject {
    static let shared = LoginItemManager()

    private let service = SMAppService.mainApp
    private let log = Logger(subsystem: "danielammann.Finder-Toolbox", category: "LoginItem")

    @Published private(set) var status: SMAppService.Status
    @Published var lastError: String?

    var isEnabled: Bool { status == .enabled }

    private init() {
        status = SMAppService.mainApp.status
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    /// Pick up out-of-band changes (user toggled the entry directly in
    /// System Settings → General → Login Items).
    @objc private func applicationDidBecomeActive() {
        refresh()
    }

    func refresh() {
        let current = service.status
        if current != status { status = current }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
            lastError = nil
        } catch {
            log.error("Login item toggle failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        status = service.status
    }
}
