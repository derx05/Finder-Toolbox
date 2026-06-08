import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Debug and diagnostics surface. Toggles drop-target logging into
/// `DebugLog`'s in-memory ring buffer, toggles per-drop result toasts,
/// and renders the log so the user can copy/save it when reporting a
/// missed-drop bug. OSLog mirroring is always on regardless of these
/// toggles — see `DebugLog`.
struct DeveloperSettingsPage: View {
    @AppStorage(DefaultsKeys.dropTargetsDebugLog) private var loggingEnabled: Bool = false
    @AppStorage(DefaultsKeys.showDropDebugPopups) private var popupsEnabled: Bool = false

    @ObservedObject private var debugLog = DebugLog.shared
    @State private var levelFilter: LevelFilter = .all
    @State private var categoryFilter: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Diagnostics for drop-target behaviour. Use these to capture details after a drop that didn't behave as expected — the in-app log persists the last 500 events while the toggle is on, and OSLog (Console.app) always captures them regardless.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                togglesCard
                logCard
            }
            .padding(20)
        }
    }

    private var togglesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            toggleRow(
                title: "Capture drop-target log",
                detail: "Record every drag-start, overlay drop, and rename outcome into an in-memory ring buffer viewable below. Off by default to keep idle cost zero.",
                isOn: $loggingEnabled
            )

            Divider().padding(.vertical, 2)

            toggleRow(
                title: "Show debug popup after each drop",
                detail: "After every drop, show a small auto-dismissing toast in the corner with the target folder, operation, and per-file outcome. Useful for catching silent failures.",
                isOn: $popupsEnabled
            )
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
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

    private var logCard: some View {
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

                Button {
                    copyAll()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(filteredEntries.isEmpty)

                Button {
                    saveAll()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                }
                .disabled(filteredEntries.isEmpty)

                Button {
                    debugLog.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(debugLog.entries.isEmpty)
            }

            logList
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
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
            let levelOK: Bool
            switch levelFilter {
            case .all:        levelOK = true
            case .warnError:  levelOK = e.level != .info
            case .errorOnly:  levelOK = e.level == .error
            }
            let catOK = categoryFilter.isEmpty || e.category.localizedCaseInsensitiveContains(categoryFilter)
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
