import SwiftUI
import Combine

/// Top-level SwiftUI app. Composes three scenes:
///
/// 1. **`settings-proxy`** — an invisible, zero-size window that exists only to
///    capture an `@Environment(\.openSettings)` action that `AppDelegate` can
///    invoke from outside SwiftUI. See `SettingsProxyView`.
/// 2. **`MenuBarExtra`** — the primary user surface in headless mode.
/// 3. **`Settings`** — the standard preferences window scene.
@main
struct FinderToolboxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var controller = AppController.shared
    @AppStorage(DefaultsKeys.menuBarShowIcon) private var showMenuBarIcon = true

    /// Template-rendered menu bar icon. Built once; size + template flag are
    /// required for correct dark-mode and tinting behaviour.
    private static let menuBarIcon: NSImage = {
        let image = NSImage(named: "menubar_icon") ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    var body: some Scene {
        // Declared first so the scene exists by the time MenuBarExtra's
        // "Settings…" button or AppDelegate try to invoke openSettings().
        Window("", id: "settings-proxy") {
            SettingsProxyView()
        }
        .defaultSize(width: 0, height: 0)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        MenuBarExtra(isInserted: .init(get: { showMenuBarIcon }, set: { _ in })) {
            MenuBarContentView()
                .environmentObject(controller)
        } label: {
            Image(nsImage: Self.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
        .windowResizability(.contentMinSize)
    }
}
