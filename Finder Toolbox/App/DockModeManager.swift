import AppKit
import Combine

enum DockMode: String, CaseIterable {
    case headless
    case settingsOnly
    case normal

    var title: String {
        switch self {
        case .headless:     "Headless mode"
        case .settingsOnly: "Show while Settings is open"
        case .normal:       "Always visible"
        }
    }

    var detail: String {
        switch self {
        case .headless:
            "The app lives entirely in the menu bar. No Dock icon ever appears."
        case .settingsOnly:
            "A Dock icon appears while the Settings window is open and disappears when you close it. Closing the window does not quit the app."
        case .normal:
            "A Dock icon is always visible. Use Cmd+Q or the menu bar to quit."
        }
    }
}

@MainActor
final class DockModeManager: ObservableObject {
    static let shared = DockModeManager()

    private static let defaultsKey = DefaultsKeys.dockMode

    @Published var mode: DockMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)

            if mode == .headless && settingsWindowIsOpen {
                // The settings window is open and may be showing a Dock icon.
                // Calling setActivationPolicy(.accessory) right now would close
                // the window, so defer the switch until the user closes it.
                deferredHeadless = true
            } else {
                deferredHeadless = false
                NSApp.setActivationPolicy(effectivePolicy)
            }
        }
    }

    private(set) var isExplicitQuit = false

    private var settingsWindowIsOpen = false

    // Set when headless mode is selected while settings is open.
    // Holds the policy at .regular until settings closes.
    private var deferredHeadless = false

    private var effectivePolicy: NSApplication.ActivationPolicy {
        switch mode {
        case .normal:        .regular
        case .settingsOnly:  settingsWindowIsOpen ? .regular : .accessory
        case .headless:      deferredHeadless ? .regular : .accessory
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        mode = DockMode(rawValue: raw) ?? .headless
        NSApp.setActivationPolicy(effectivePolicy)
    }

    func willOpenSettings() {
        settingsWindowIsOpen = true
        if mode == .settingsOnly {
            NSApp.setActivationPolicy(.regular)
        }
        // headless: policy stays .accessory — no Dock icon while settings is open.
        // normal: already .regular, nothing to do.
    }

    // Called from SettingsView.onDisappear.
    func settingsDidClose() {
        settingsWindowIsOpen = false
        deferredHeadless = false
        NSApp.setActivationPolicy(effectivePolicy)
    }

    // Called by "Quit" buttons — bypasses the Cmd+Q guard in non-normal modes.
    func explicitQuit() {
        isExplicitQuit = true
        NSApplication.shared.terminate(nil)
    }

    // Called by Sparkle before it relaunches the app after an update.
    func prepareForSparkleRelaunch() {
        isExplicitQuit = true
    }
}
