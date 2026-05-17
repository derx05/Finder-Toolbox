import SwiftUI

/// Inline `info.circle` button that opens a popover with a before/after
/// example for a rename setting.
struct InfoPopover: View {
    let title: String
    let detail: String
    let exampleBefore: String
    let exampleAfter: String

    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isShowing, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 8) {
                    Text(exampleBefore)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                    Text(exampleAfter)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(.subheadline, design: .monospaced))
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}
