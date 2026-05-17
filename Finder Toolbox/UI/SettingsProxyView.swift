import SwiftUI
import AppKit

/// Invisible scene-keeper used to expose `@Environment(\.openSettings)` to
/// non-SwiftUI code (`AppDelegate`).
///
/// SwiftUI emits a "Please use SettingsLink" runtime warning if you call
/// `openSettings()` from outside a view hierarchy. This view captures the
/// environment value into `AppController.openSettingsAction`, then orders
/// its host window out of view — the scene stays alive for the session
/// but is never visible.
struct SettingsProxyView: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppController.shared.openSettingsAction = { openSettings() }
                // Defer orderOut until after the window has finished presenting,
                // otherwise the close races the show and AppKit logs a warning.
                DispatchQueue.main.async {
                    NSApp.windows
                        .first { $0.identifier?.rawValue == "settings-proxy" }?
                        .orderOut(nil)
                }
            }
    }
}
