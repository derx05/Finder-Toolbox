import Foundation
import AppKit
import Combine
import Sparkle

/// User-selectable release channel.
///
/// Each value maps to a `<sparkle:channel>` element in the appcast item. The
/// default (release) channel has no element — it is implicit and always
/// allowed by Sparkle regardless of the user's pick. Higher tiers are
/// supersets: a user on `.beta` also sees release builds; a user on
/// `.development` sees all three. This matches how most macOS apps surface
/// "show me pre-release builds" without forcing the user to manually downgrade
/// when a stable release ships.
///
/// The raw value is what we write into the appcast XML and what we persist
/// in `UserDefaults`. Don't rename these without a migration.
enum UpdateChannel: String, CaseIterable, Identifiable {
    case release
    case beta
    case development

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .release:     "Release"
        case .beta:        "Beta"
        case .development: "Development"
        }
    }

    /// Channel tags Sparkle should accept for this user pick. Items with no
    /// `<sparkle:channel>` element are always considered the default channel
    /// and pass regardless of what we return here.
    var allowedChannelTags: Set<String> {
        switch self {
        case .release:     []
        case .beta:        ["beta"]
        case .development: ["beta", "development"]
        }
    }

    static var current: UpdateChannel {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.updatesChannel),
              let channel = UpdateChannel(rawValue: raw)
        else { return .release }
        return channel
    }
}

/// Thin wrapper around `SPUStandardUpdaterController` that:
///
/// - bridges `UpdateChannel.current` into Sparkle via `allowedChannels(for:)`,
/// - exposes `lastUpdateCheckDate` and `canCheckForUpdates` as `@Published`
///   properties the SwiftUI About page can observe directly.
///
/// Sparkle reads `allowedChannels` fresh each time it processes the appcast,
/// so flipping the channel picker takes effect on the next check without a
/// relaunch.
///
/// `automaticallyChecksForUpdates` / `automaticallyDownloadsUpdates` live in
/// `UserDefaults` under Sparkle's own keys (`SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate`). We mirror them under our own
/// `DefaultsKeys.updatesAutoCheck` / `updatesAutoDownload` so the About page
/// can bind via `@AppStorage` without taking a hard dependency on Sparkle.
@MainActor
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var canCheckForUpdates: Bool = false

    private var controller: SPUStandardUpdaterController!
    private var canCheckObservation: NSKeyValueObservation?
    private var cancellables: Set<AnyCancellable> = []

    var updater: SPUUpdater { controller.updater }

    override init() {
        super.init()
        // `startingUpdater: false` so we can mirror persisted prefs into
        // Sparkle before the first scheduled check fires.
        self.controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        // KVO on `canCheckForUpdates`. Sparkle flips this false while a check
        // is in flight; the About page uses it to disable the button.
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            // KVO callbacks can arrive on any thread.
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }

        // Keep our `updatesLastChecked` mirror current. Sparkle doesn't post
        // a notification when a check finishes, but it does write to
        // `UserDefaults`, so the defaults-changed notification is a reliable
        // edge to read `lastUpdateCheckDate` from.
        lastUpdateCheckDate = controller.updater.lastUpdateCheckDate

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let date = self.controller.updater.lastUpdateCheckDate
                if date != self.lastUpdateCheckDate {
                    self.lastUpdateCheckDate = date
                    if let date {
                        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: DefaultsKeys.updatesLastChecked)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Called once from `AppDelegate.applicationDidFinishLaunching` so Sparkle
    /// starts after `UpdateChannel.current` is readable and after the dock-mode
    /// manager has applied its activation policy.
    func start() {
        // Mirror the persisted auto-check / auto-download prefs into Sparkle.
        // First-launch defaults: auto-check on (low cost, no UX surprise — no
        // popup, just a badge), auto-download off (we don't want to surprise
        // users with a downloaded `.zip` they didn't ask for).
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKeys.updatesAutoCheck) == nil {
            defaults.set(true, forKey: DefaultsKeys.updatesAutoCheck)
        }
        controller.updater.automaticallyChecksForUpdates =
            defaults.bool(forKey: DefaultsKeys.updatesAutoCheck)
        controller.updater.automaticallyDownloadsUpdates =
            defaults.bool(forKey: DefaultsKeys.updatesAutoDownload)

        // Keep Sparkle in sync if the user toggles the About page switches.
        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let d = UserDefaults.standard
                let auto = d.bool(forKey: DefaultsKeys.updatesAutoCheck)
                let download = d.bool(forKey: DefaultsKeys.updatesAutoDownload)
                if self.controller.updater.automaticallyChecksForUpdates != auto {
                    self.controller.updater.automaticallyChecksForUpdates = auto
                }
                if self.controller.updater.automaticallyDownloadsUpdates != download {
                    self.controller.updater.automaticallyDownloadsUpdates = download
                }
            }
            .store(in: &cancellables)

        controller.startUpdater()
    }

    /// User pressed "Check for Updates".
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Sparkle calls this on its own thread. `UpdateChannel.current` only
        // reads `UserDefaults`, which is thread-safe.
        UpdateChannel.current.allowedChannelTags
    }
}
