import SwiftUI
import AppKit

/// The SwiftUI content rendered inside the notch feedback panel.
/// Clipping and shadow are handled at the CALayer level by the panel's container
/// view — this view should not apply clipShape or shadow.
struct NotchFeedbackView: View {

    @ObservedObject var model: NotchFeedbackModel
    /// Physical notch dead-zone height from NSScreen.safeAreaInsets.top.
    /// 0 on non-notch screens.
    let topInset: CGFloat

    private var hasNotch: Bool { topInset > 0 }

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .padding(.top, topInset)
                // Fade in after the shape has grown; controller sets this flag
                // once the expand animation is near completion.
                .opacity(model.contentVisible ? 1 : 0)
                .animation(.easeIn(duration: 0.2), value: model.contentVisible)
        }
        .onHover { isHovered = $0 }
    }

    // MARK: - Background

    private var background: some View {
        Group {
            if hasNotch {
                // Pure black blends with the physical notch camera cutout.
                Color.black
            } else {
                // Dark vibrancy pill on non-notch screens.
                VisualEffectBackground()
                    .overlay(Color.black.opacity(0.5))
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .progress(let message, let value):
            progressContent(message: message, value: value)
        case .success(let message):
            resultContent(icon: "checkmark.circle.fill", iconColor: .green, message: message)
        case .warning(let message, let detail):
            expandableContent(icon: "exclamationmark.circle.fill", iconColor: .yellow,
                              message: message, detail: detail)
        case .error(let message, let detail):
            expandableContent(icon: "xmark.circle.fill", iconColor: .red,
                              message: message, detail: detail)
        }
    }

    private func progressContent(message: String, value: Double?) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                if value == nil {
                    IndeterminateSpinner()
                        .frame(width: 14, height: 14)
                }
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            if let v = value {
                ProgressBar(value: v)
                    .frame(height: 4)
            }
        }
    }

    private func resultContent(icon: String, iconColor: Color, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
    }

    private func expandableContent(icon: String, iconColor: Color, message: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 16, weight: .semibold))

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if detail != nil {
                    Image(systemName: model.isDetailExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .animation(.easeInOut(duration: 0.2), value: model.isDetailExpanded)
                }
            }

            if let detail, (isHovered || model.isDetailExpanded) {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.leading, 24)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard detail != nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                model.isDetailExpanded.toggle()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }
}

// MARK: - Supporting views

private struct ProgressBar: View {
    let value: Double  // 0.0 – 1.0

    var body: some View {
        // scaleEffect(x:anchor:) avoids GeometryReader, which can cause layout
        // instability when nested inside an animated clip container.
        Capsule()
            .fill(Color.white.opacity(0.2))
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.white)
                    .scaleEffect(x: max(0, min(1, value)), anchor: .leading)
                    .animation(.linear(duration: 0.15), value: value)
            }
    }
}

private struct IndeterminateSpinner: View {
    @State private var angle: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
