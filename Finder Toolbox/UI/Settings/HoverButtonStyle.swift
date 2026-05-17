import SwiftUI

/// Borderless button style with a subtle hover/press tint.
///
/// Used in the About page for the Quit and GitHub buttons. Picks up its
/// colour from the `tint` parameter rather than the system accent so the
/// destructive Quit button reads as red while other actions stay neutral.
struct HoverButtonStyle: ButtonStyle {
    var tint: Color = .primary

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill((isHovered || configuration.isPressed) ? tint.opacity(0.1) : Color.clear)
            )
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
