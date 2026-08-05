import Foundation
import AppKit
import ApplicationServices
import Combine
import Carbon

@MainActor
final class PermissionsManager: ObservableObject {
    static let shared = PermissionsManager()

    enum Status {
        case unknown, authorized, denied
    }

    @Published private(set) var finderAutomationStatus: Status = .unknown

    /// Mail Automation grant. Required only for the Mail-drag path of the
    /// drop-targets feature (.eml export via AppleScript). Probed via
    /// `AEDeterminePermissionToAutomateTarget` so we never launch Mail
    /// just to check.
    @Published private(set) var mailAutomationStatus: Status = .unknown

    /// Mirrors `hasFullDiskAccess()` as a publishable property so SwiftUI
    /// views (the Permissions settings page) can observe live changes
    /// after the user toggles FDA in System Settings.
    @Published private(set) var fullDiskAccessStatus: Status = .unknown

    /// TCC Accessibility grant. Needed only to post synthetic keystrokes
    /// for the insert-date hotkey (`DateInserter`). Probed with
    /// `AXIsProcessTrusted()`, which never prompts.
    @Published private(set) var accessibilityStatus: Status = .unknown

    func markDenied() { finderAutomationStatus = .denied }

    private init() {}

    /// Re-probes every permission and publishes the result. Called by the
    /// Permissions settings page when it appears and when the app becomes
    /// active again (covering the System Settings round-trip).
    ///
    /// The Automation and FDA probes run concurrently off the main thread
    /// so `AEDeterminePermissionToAutomateTarget` never blocks the main
    /// actor while SwiftUI is trying to render. Results are published
    /// together once all probes complete. `AXIsProcessTrusted` is a cheap
    /// local check and stays on the main actor.
    func refreshAll() async {
        finderAutomationStatus = .unknown
        mailAutomationStatus = .unknown
        fullDiskAccessStatus = .unknown
        accessibilityStatus = .unknown

        async let finder: Status = Task.detached(priority: .userInitiated) {
            Self.probeAutomation(bundleID: "com.apple.finder", askUserIfNeeded: false)
        }.value
        async let mail: Status = Task.detached(priority: .userInitiated) {
            Self.probeAutomation(bundleID: "com.apple.mail", askUserIfNeeded: false)
        }.value
        async let fda: Bool = Task.detached(priority: .userInitiated) {
            FileManager.default.isReadableFile(
                atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
            )
        }.value

        finderAutomationStatus = await finder
        mailAutomationStatus = await mail
        fullDiskAccessStatus = await fda ? .authorized : .denied
        accessibilityStatus = AXIsProcessTrusted() ? .authorized : .denied
    }

    func checkAccessibility() {
        accessibilityStatus = AXIsProcessTrusted() ? .authorized : .denied
    }

    /// Raise the system Accessibility prompt (the "Open System Settings"
    /// alert). macOS shows it only while no TCC decision exists for this
    /// app; once the user has answered once, the alert is suppressed and
    /// System Settings is the only route — which is why the Permissions
    /// page always offers the deep link alongside this.
    ///
    /// The grant does not apply to the running process: macOS requires the
    /// app to be relaunched after it's ticked. The settings UI says so.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityStatus = AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
    }

    /// True when synthetic keystrokes can actually be posted. Callers use
    /// this to short-circuit with a clear message instead of silently
    /// posting events the window server drops.
    nonisolated func hasAccessibility() -> Bool {
        AXIsProcessTrusted()
    }

    func checkPermission() async {
        guard finderAutomationStatus == .unknown else { return }
        finderAutomationStatus = await Task.detached(priority: .userInitiated) {
            Self.probeAutomation(bundleID: "com.apple.finder", askUserIfNeeded: false)
        }.value
    }

    func checkMailAutomation() async {
        guard mailAutomationStatus == .unknown else { return }
        mailAutomationStatus = await Task.detached(priority: .userInitiated) {
            Self.probeAutomation(bundleID: "com.apple.mail", askUserIfNeeded: false)
        }.value
    }

    func checkFullDiskAccess() async {
        guard fullDiskAccessStatus == .unknown else { return }
        fullDiskAccessStatus = await Task.detached(priority: .userInitiated) {
            FileManager.default.isReadableFile(
                atPath: "/Library/Application Support/com.apple.TCC/TCC.db"
            )
        }.value ? .authorized : .denied
    }

    /// Surface the system Automation prompt for Finder. macOS shows the
    /// dialog if no TCC record exists for this app/target pair yet; if
    /// the user previously denied it, the call returns without
    /// re-prompting and the user has to go through System Settings.
    /// Run off-main because the prompt blocks the calling thread.
    func requestFinderAutomation() async {
        let result = await Task.detached(priority: .userInitiated) {
            Self.probeAutomation(bundleID: "com.apple.finder", askUserIfNeeded: true)
        }.value
        finderAutomationStatus = result
    }

    /// Mirror of `requestFinderAutomation` for Mail — only relevant to
    /// the Mail-drag path of the drop-targets feature.
    func requestMailAutomation() async {
        let result = await Task.detached(priority: .userInitiated) {
            Self.probeAutomation(bundleID: "com.apple.mail", askUserIfNeeded: true)
        }.value
        mailAutomationStatus = result
    }

    nonisolated private static func probeAutomation(bundleID: String, askUserIfNeeded: Bool) -> Status {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descPtr = target.aeDesc else { return .unknown }
        var desc = descPtr.pointee
        let status = AEDeterminePermissionToAutomateTarget(
            &desc,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
        switch status {
        case noErr:                                          return .authorized
        case OSStatus(errAEEventNotPermitted):               return .denied
        case -1744 /* errAEEventWouldRequireUserConsent */:  return .denied
        default:                                             return .unknown
        }
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

    /// True if the source URL lives inside another app's sandbox container
    /// (`~/Library/Containers/<bundle>/Data/...`). The canonical case is
    /// Mail attachments under `~/Library/Containers/com.apple.mail/Data/
    /// Library/Mail Downloads/` — reading those requires Full Disk Access.
    /// Without FDA, both the Finder Apple Events path and our FileManager
    /// fallback fail with cryptic errors instead of a clear "grant FDA"
    /// signal. Detect upfront so callers can surface the recovery dialog.
    func isTCCGatedSource(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let containersPrefix = "\(NSHomeDirectory())/Library/Containers/"
        return path.hasPrefix(containersPrefix)
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
