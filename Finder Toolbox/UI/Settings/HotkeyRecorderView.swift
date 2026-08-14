import SwiftUI
import AppKit

/// Settings row that presents a feature's full shortcut (prefix + key) and
/// offers a "click to record" affordance for the *key* part only. The
/// modifier prefix is an app-wide setting (General → Keyboard shortcuts);
/// here the user records just a key, optionally with ⇧ for variants like
/// "same key, shifted = recursive".
struct HotkeyRow: View {
    let title: String
    let label: String
    @Binding var isRecording: Bool
    /// Called with the recorded key code and whether ⇧ was held.
    let onNewKey: (UInt16, Bool) -> Void

    init(
        title: String = "Global Shortcut",
        label: String,
        isRecording: Binding<Bool>,
        onNewKey: @escaping (UInt16, Bool) -> Void
    ) {
        self.title = title
        self.label = label
        self._isRecording = isRecording
        self.onNewKey = onNewKey
    }

    var body: some View {
        LabeledContent(title) {
            HotkeyRecorderView(
                displayLabel: isRecording ? "Press key…" : label,
                isRecording: isRecording,
                onTap: { isRecording = true },
                onNewKey: { keyCode, shift in
                    isRecording = false
                    onNewKey(keyCode, shift)
                },
                onCancel: { isRecording = false }
            )
            .frame(width: 140)
        }
    }
}

/// NSButton subclass that records the next key the user presses while in
/// recording mode. Only ⇧ is honored as part of the recording — the other
/// modifiers belong to the shared prefix and are stripped, so pressing the
/// full combo out of habit records the same thing as pressing the bare key.
///
/// We sit on the AppKit level rather than using a SwiftUI key handler so we
/// can intercept the raw `keyCode` — SwiftUI's key handling normalises some
/// keys (e.g. swallows arrows and function keys) that we want to bind.
struct HotkeyRecorderView: NSViewRepresentable {
    let displayLabel: String
    let isRecording: Bool
    let onTap: () -> Void
    let onNewKey: (UInt16, Bool) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.tapped)
        context.coordinator.view = button
        context.coordinator.onNewKey = onNewKey
        context.coordinator.onCancel = onCancel
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = displayLabel
        button.isRecording = isRecording
        context.coordinator.onNewKey = onNewKey
        context.coordinator.onCancel = onCancel
        if isRecording {
            button.window?.makeFirstResponder(button)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        weak var view: RecorderButton?
        var onTap: () -> Void
        var onNewKey: ((UInt16, Bool) -> Void)?
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

            let shift = event.modifierFlags.contains(.shift)
            (target as? Coordinator)?.onNewKey?(event.keyCode, shift)
        }
    }
}
