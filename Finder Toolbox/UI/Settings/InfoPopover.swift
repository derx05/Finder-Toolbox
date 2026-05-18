import SwiftUI

/// Inline `info.circle` button that opens a popover with a before/after
/// example for a rename setting.
struct InfoPopover: View {
    let title: String
    let detail: String
    let exampleBefore: String?
    let exampleAfter: String?

    @State private var isShowing = false

    init(title: String, detail: String, exampleBefore: String? = nil, exampleAfter: String? = nil) {
        self.title = title
        self.detail = detail
        self.exampleBefore = exampleBefore
        self.exampleAfter = exampleAfter
    }

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

                if let before = exampleBefore, let after = exampleAfter {
                    Divider()

                    HStack(spacing: 8) {
                        Text(before)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                        Text(after)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(.subheadline, design: .monospaced))
                }
            }
            .padding(16)
            .frame(width: 300)
        }
    }
}
