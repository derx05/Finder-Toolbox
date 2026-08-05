import Foundation

/// What the app may ask the user to grant, and which features each
/// grant unlocks. Single source of truth consumed by both the
/// Permissions settings page (transparency UI) and the runtime
/// short-circuits (e.g. proactive FDA check before a TCC-gated drop).
///
/// When a new feature is added that needs a permission, list it here
/// rather than scattering string literals across the settings UI.
enum PermissionsCatalog {

    enum Kind: Hashable {
        case automation        // com.apple.security.automation.apple-events → Finder
        case automationMail    // com.apple.security.automation.apple-events → Mail
        case fullDiskAccess    // kTCCServiceSystemPolicyAllFiles
        case accessibility     // kTCCServiceAccessibility
    }

    struct Feature: Hashable {
        let name: String
        /// One-line explanation of what the feature does *with* the
        /// permission. Phrased so it's intelligible without the
        /// permission's context already in the user's head.
        let detail: String
        /// `true` if the feature stops working entirely without the
        /// permission. `false` if the feature still works in some
        /// modes but loses scope (e.g. the rename hotkey still works
        /// inside non-protected folders without FDA).
        let isRequired: Bool
    }

    struct Entry {
        let kind: Kind
        let displayName: String
        /// What macOS will show in its prompt, kept consistent with the
        /// Info.plist usage description.
        let purpose: String
        /// Why a user might *not* want to grant this — surfaced so the
        /// transparency UI doesn't read as marketing copy.
        let tradeoff: String?
        let features: [Feature]
        /// Deep link into the relevant System Settings pane. macOS
        /// `x-apple.systempreferences:` schema.
        let settingsURL: URL?
    }

    static let all: [Entry] = [
        Entry(
            kind: .automation,
            displayName: "Automation (Finder)",
            purpose: "Send commands to Finder to read the current selection and to rename files. Every rename runs through Finder so it lands in Finder's native Undo stack.",
            tradeoff: nil,
            features: [
                Feature(
                    name: "Hotkey rename",
                    detail: "Press the global hotkey to rename Finder's current selection.",
                    isRequired: true
                ),
                Feature(
                    name: "Drag-time drop targets",
                    detail: "Overlay pills over Finder windows let you drop files to rename and route them.",
                    isRequired: true
                ),
            ],
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        ),
        Entry(
            kind: .automationMail,
            displayName: "Automation (Mail)",
            purpose: "Ask Mail to export the messages you drag onto a drop target as .eml files. Mail's drag-and-drop API doesn't fulfill file promises for any destination other than Finder, so AppleScript is the only supported way to receive a message drag.",
            tradeoff: "Only relevant if you drag messages from Mail.app onto Finder Toolbox drop overlays. Without this grant, Mail drags are ignored; every other drop-target source (Finder, Safari, Photos, SMB shares, etc.) still works.",
            features: [
                Feature(
                    name: "Drop messages from Mail.app",
                    detail: "Dragging one or more messages from Mail onto a drop overlay exports them as .eml files into the destination folder and renames them with the smart-date pipeline (using the Date: header).",
                    isRequired: true
                ),
            ],
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        ),
        Entry(
            kind: .fullDiskAccess,
            displayName: "Full Disk Access",
            purpose: "Lets Finder Toolbox move files into TCC-protected folders (the home folder root, Desktop, Documents, Downloads, etc.). macOS attributes the destination check to the AppleScript caller, not to Finder, so without this grant cross-folder moves into those locations fail.",
            tradeoff: "Broad permission — Finder Toolbox can read your entire user library while it's granted. Only needed if you want to drop files into TCC-protected folders. The hotkey rename works without it; drops into other folders work too.",
            features: [
                Feature(
                    name: "Drop into protected folders",
                    detail: "Drop files onto overlays for the home folder, Desktop, Documents, Downloads, etc.",
                    isRequired: true
                ),
                Feature(
                    name: "Drop into other folders",
                    detail: "Works without this permission — only protected folders require it.",
                    isRequired: false
                ),
            ],
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        ),
        Entry(
            kind: .accessibility,
            displayName: "Accessibility",
            purpose: "Type today's date into the text field you're working in. macOS treats synthesized keystrokes as an accessibility capability, so posting them requires this grant.",
            tradeoff: "Only relevant if you use the insert-date hotkey, which is off by default. The grant is broad — while it's active Finder Toolbox could read the screen and drive other apps. It uses it for exactly one thing: posting the characters of the date you asked for. Renaming and drop targets never need it.",
            features: [
                Feature(
                    name: "Insert today's date",
                    detail: "Press the insert-date hotkey and today's date is typed into whatever text field has focus, in any app.",
                    isRequired: true
                ),
            ],
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        ),
    ]
}
