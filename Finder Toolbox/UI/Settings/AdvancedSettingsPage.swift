import SwiftUI
import AppKit

/// Transparency page listing every filesystem location the app may read or
/// write. Mirrors the philosophy of the Permissions page: surface the
/// implementation detail so the user never has to grep their Library to
/// find out where the app hides state.
struct AdvancedSettingsPage: View {
    @State private var sizes: [UUID: SizeState] = [:]

    private let entries = StorageLocationsCatalog.all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Every filesystem location Finder Toolbox may read or write outside of the files you ask it to rename. Use this to audit what the app has stored, or to manually clean up before uninstalling.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                ForEach(entries) { entry in
                    StorageLocationCard(
                        entry: entry,
                        sizeState: sizes[entry.id] ?? .pending,
                        onMeasure: { measure(entry) }
                    )
                }
            }
            .padding(20)
        }
        .task {
            for entry in entries { await measureAsync(entry) }
        }
    }

    private func measure(_ entry: StorageLocationsCatalog.Entry) {
        Task { await measureAsync(entry) }
    }

    private func measureAsync(_ entry: StorageLocationsCatalog.Entry) async {
        sizes[entry.id] = .measuring
        let url = entry.url
        let state = await Task.detached(priority: .utility) { () -> SizeState in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                return .missing
            }
            if isDir.boolValue {
                return .ready(bytes: directorySize(at: url))
            } else {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return .ready(bytes: size)
            }
        }.value
        sizes[entry.id] = state
    }
}

nonisolated private func directorySize(at root: URL) -> Int64 {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey],
        options: [.skipsHiddenFiles],
        errorHandler: nil
    ) else { return 0 }

    var total: Int64 = 0
    for case let url as URL in enumerator {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        guard values?.isRegularFile == true else { continue }
        let bytes = values?.totalFileAllocatedSize ?? values?.fileSize ?? 0
        total += Int64(bytes)
    }
    return total
}

private enum SizeState {
    case pending
    case measuring
    case ready(bytes: Int64)
    case missing
}

private struct StorageLocationCard: View {
    let entry: StorageLocationsCatalog.Entry
    let sizeState: SizeState
    let onMeasure: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayName)
                    .font(.headline)
                Spacer()
                StorageSizeBadge(state: sizeState)
            }

            Text(entry.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.url.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button {
                    reveal()
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.right.circle")
                }
                .disabled(!revealable)

                Button {
                    copyPath()
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }

                Spacer()

                Button {
                    onMeasure()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Recalculate size")
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .controlSize(.regular)
            .padding(.top, 2)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }

    private var exists: Bool {
        FileManager.default.fileExists(atPath: entry.url.path)
    }

    /// We can reveal if the target exists, OR if its parent exists (so the
    /// user can at least see the directory it would be created in).
    private var revealable: Bool {
        exists || FileManager.default.fileExists(atPath: entry.url.deletingLastPathComponent().path)
    }

    private func reveal() {
        if exists {
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        } else {
            // Fall back to opening the parent directory.
            let parent = entry.url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                NSWorkspace.shared.open(parent)
            }
        }
    }

    private func copyPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.url.path, forType: .string)
    }
}

private struct StorageSizeBadge: View {
    let state: SizeState

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch state {
        case .ready:     .green
        case .missing:   .gray
        case .measuring, .pending: .secondary
        }
    }

    private var label: String {
        switch state {
        case .pending:        "—"
        case .measuring:      "Measuring…"
        case .missing:        "Not present"
        case .ready(let b):   Self.formatter.string(fromByteCount: b)
        }
    }

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()
}
