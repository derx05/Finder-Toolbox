import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct DeveloperSettingsPage: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                NotchFeedbackSection()
                DropDiagnosticsSection()
            }
            .padding(20)
        }
    }
}

// MARK: - Collapsible card

private struct DevCard<Content: View>: View {
    let title: String
    let subtitle: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — always visible
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)
                content()
                    .padding(14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - Notch Feedback section

private struct NotchFeedbackSection: View {
    @State private var isExpanded: Bool = false

    @State private var progressMessage: String = "Processing 12 files…"
    @State private var progressValue: Double = 0.6
    @State private var indeterminate: Bool = false
    @State private var successMessage: String = "12 files renamed"
    @State private var errorMessage: String = "2 files failed"
    @State private var errorDetail: String = "invoice.pdf: Permission denied\nreport.docx: File in use"

    var body: some View {
        DevCard(
            title: "Notch Feedback",
            subtitle: "Try the notch (or top-center pill on non-notch screens) feedback element.",
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 16) {
                progressDemo
                Divider()
                successDemo
                Divider()
                errorDemo
                Divider()
                Button("Dismiss") {
                    NotchFeedbackController.shared.dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var progressDemo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Progress", systemImage: "chart.bar.fill")
                .font(.subheadline.weight(.medium))
            HStack {
                TextField("Message", text: $progressMessage)
                    .textFieldStyle(.roundedBorder)
                Toggle("Indeterminate", isOn: $indeterminate)
                    .toggleStyle(.checkbox)
            }
            if !indeterminate {
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", progressValue * 100))
                        .font(.caption.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                    Slider(value: $progressValue, in: 0...1)
                }
            }
            Button("Show progress") {
                NotchFeedbackController.shared.showProgress(
                    progressMessage,
                    value: indeterminate ? nil : progressValue
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private var successDemo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Success  (auto-dismisses after 2.5 s)", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.medium))
            TextField("Message", text: $successMessage)
                .textFieldStyle(.roundedBorder)
            Button("Show success") {
                NotchFeedbackController.shared.showSuccess(successMessage)
            }
            .buttonStyle(.bordered)
        }
    }

    private var errorDemo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Error  (hover or tap to expand detail)", systemImage: "xmark.circle.fill")
                .font(.subheadline.weight(.medium))
            TextField("Short message", text: $errorMessage)
                .textFieldStyle(.roundedBorder)
            TextField("Detail (optional)", text: $errorDetail, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
            Button("Show error") {
                let detail = errorDetail.trimmingCharacters(in: .whitespacesAndNewlines)
                NotchFeedbackController.shared.showError(
                    errorMessage,
                    detail: detail.isEmpty ? nil : detail
                )
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - Drop Diagnostics section

private struct DropDiagnosticsSection: View {
    @State private var isExpanded: Bool = false

    @AppStorage(DefaultsKeys.dropTargetsDebugLog) private var loggingEnabled: Bool = false
    @AppStorage(DefaultsKeys.showDropDebugPopups) private var popupsEnabled: Bool = false

    @ObservedObject private var debugLog = DebugLog.shared
    @State private var levelFilter: LevelFilter = .all
    @State private var categoryFilter: String = ""

    var body: some View {
        DevCard(
            title: "Drop Target Diagnostics",
            subtitle: "Capture per-drop logs and result toasts to diagnose missed or misrouted drops.",
            isExpanded: $isExpanded
        ) {
            VStack(alignment: .leading, spacing: 14) {
                togglesGroup
                logGroup
            }
        }
    }

    private var togglesGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow(
                title: "Capture drop-target log",
                detail: "Record drag-start, overlay drop, and rename outcomes into an in-memory ring buffer (max 500 entries). OSLog always captures regardless of this toggle.",
                isOn: $loggingEnabled
            )
            Divider().padding(.vertical, 2)
            toggleRow(
                title: "Show debug popup after each drop",
                detail: "Auto-dismissing toast after every drop showing target folder, operation, and per-file outcome.",
                isOn: $popupsEnabled
            )
        }
    }

    private func toggleRow(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }

    private var logGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Log").font(.headline)
                Spacer()
                Text("\(filteredEntries.count) / \(debugLog.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Picker("", selection: $levelFilter) {
                    ForEach(LevelFilter.allCases, id: \.self) { f in
                        Text(f.label).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                TextField("Filter by category…", text: $categoryFilter)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Button { copyAll() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(filteredEntries.isEmpty)

                Button { saveAll() } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(filteredEntries.isEmpty)

                Button { debugLog.clear() } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(debugLog.entries.isEmpty)
            }

            logList
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue.uppercased())
                                .foregroundStyle(color(for: entry.level))
                                .frame(width: 56, alignment: .leading)
                            Text(entry.category)
                                .foregroundStyle(.secondary)
                                .frame(width: 140, alignment: .leading)
                            Text(entry.message)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .padding(.vertical, 1)
                        .id(entry.id)
                    }
                }
                .padding(8)
            }
            .frame(minHeight: 280, maxHeight: 420)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
            .onChange(of: debugLog.entries.count) {
                if let last = debugLog.entries.last?.id {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var filteredEntries: [DebugLog.Entry] {
        debugLog.entries.filter { e in
            let levelOK: Bool = switch levelFilter {
            case .all:       true
            case .warnError: e.level != .info
            case .errorOnly: e.level == .error
            }
            let catOK = categoryFilter.isEmpty ||
                        e.category.localizedCaseInsensitiveContains(categoryFilter)
            return levelOK && catOK
        }
    }

    private func copyAll() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(exportText(), forType: .string)
    }

    private func saveAll() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "finder-toolbox-debug-\(Int(Date().timeIntervalSince1970)).log"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportText() -> String {
        filteredEntries.map { e in
            "\(Self.isoFormatter.string(from: e.timestamp)) [\(e.level.rawValue.uppercased())] \(e.category): \(e.message)"
        }.joined(separator: "\n")
    }

    private func color(for level: DebugLog.Level) -> Color {
        switch level {
        case .info:    .secondary
        case .warning: .orange
        case .error:   .red
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

private enum LevelFilter: CaseIterable, Hashable {
    case all, warnError, errorOnly
    var label: String {
        switch self {
        case .all:       "All"
        case .warnError: "Warn+Error"
        case .errorOnly: "Error"
        }
    }
}
