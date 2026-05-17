import SwiftUI
import AppKit

/// Settings row that presents the current global shortcut and offers a
/// "click to record" affordance.
struct HotkeyRow: View {
    let label: String
    @Binding var isRecording: Bool
    let onNewShortcut: (UInt16, NSEvent.ModifierFlags) -> Void

    var body: some View {
        LabeledContent("Global Shortcut") {
            HotkeyRecorderView(
                displayLabel: isRecording ? "Press keys…" : label,
                isRecording: isRecording,
                onTap: { isRecording = true },
                onNewShortcut: { keyCode, mods in
                    isRecording = false
                    onNewShortcut(keyCode, mods)
                },
                onCancel: { isRecording = false }
            )
            .frame(width: 140)
        }
    }
}

/// NSButton subclass that records the next chord (modifier+key) the user
/// presses while in recording mode.
///
/// We sit on the AppKit level rather than using a SwiftUI key handler so we
/// can intercept the raw `keyCode` — SwiftUI's key handling normalises some
/// keys (e.g. swallows arrows and function keys) that we want to bind.
struct HotkeyRecorderView: NSViewRepresentable {
    let displayLabel: String
    let isRecording: Bool
    let onTap: () -> Void
    let onNewShortcut: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.tapped)
        context.coordinator.view = button
        context.coordinator.onNewShortcut = onNewShortcut
        context.coordinator.onCancel = onCancel
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = displayLabel
        button.isRecording = isRecording
        context.coordinator.onNewShortcut = onNewShortcut
        context.coordinator.onCancel = onCancel
        if isRecording {
            button.window?.makeFirstResponder(button)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        weak var view: RecorderButton?
        var onTap: () -> Void
        var onNewShortcut: ((UInt16, NSEvent.ModifierFlags) -> Void)?
        var onCancel: (() -> Void)?

        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        @objc func tapped() { onTap() }
    }

    final class RecorderButton: NSButton {
        var isRecording = false

        // First responder is required to receive keyDown events. Refuse the
        // responder role outside of recording so the button doesn't steal
        // keyboard focus during normal navigation.
        override var acceptsFirstResponder: Bool { isRecording }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }

            // Escape cancels without recording.
            if event.keyCode == 53 {  // kVK_Escape
                (target as? Coordinator)?.onCancel?()
                return
            }

            // Require at least one modifier — bare keys would conflict with
            // typing in any other app.
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard !mods.isEmpty else { return }

            (target as? Coordinator)?.onNewShortcut?(event.keyCode, mods)
        }
    }
}
