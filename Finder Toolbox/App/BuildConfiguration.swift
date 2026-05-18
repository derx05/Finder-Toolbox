import Foundation

/// Compile-time build flavour. Used by the About panel to surface a warning
/// banner when the running binary is a debug build, and by `AppDelegate` to
/// terminate any already-running release instance on launch (so Xcode runs
/// don't fight a previously-launched menu bar copy for the global hotkey).
enum BuildConfiguration {
    static let isDebug: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()
}
