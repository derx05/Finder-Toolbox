import SwiftUI
import AppKit

/// Transparency page: every TCC permission the app may request, what
/// each one is used for, the current status, and which features each
/// permission enables. Designed so the user never has to guess "what
/// happens if I revoke this".
///
/// Status is re-probed on appear and whenever the app becomes active
/// again (covering the round-trip to System Settings).
struct PermissionsSettingsPage: View {
    @ObservedObject private var permissions = PermissionsManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Finder Toolbox tries to be explicit about every permission it asks macOS for. Each entry below shows the live status, why the permission is needed, and which features depend on it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 4)

                ForEach(Array(PermissionsCatalog.all.enumerated()), id: \.offset) { _, entry in
                    PermissionCard(entry: entry, status: status(for: entry.kind))
                }
            }
            .padding(20)
        }
        .task { await permissions.refreshAll() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await permissions.refreshAll() }
        }
    }

    private func status(for kind: PermissionsCatalog.Kind) -> PermissionsManager.Status {
        switch kind {
        case .automation:     permissions.finderAutomationStatus
        case .fullDiskAccess: permissions.fullDiskAccessStatus
        }
    }
}

private struct PermissionCard: View {
    let entry: PermissionsCatalog.Entry
    let status: PermissionsManager.Status

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayName)
                    .font(.headline)
                Spacer()
                StatusBadge(status: status)
            }

            Text(entry.purpose)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let tradeoff = entry.tradeoff {
                Text(tradeoff)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("Features that depend on this permission")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(entry.features, id: \.self) { feature in
                    FeatureRow(feature: feature, status: status)
                }
            }

            if let url = entry.settingsURL {
                HStack {
                    Spacer()
                    Button("Open in System Settings") {
                        NSWorkspace.shared.open(url)
                    }
                    .controlSize(.regular)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private struct StatusBadge: View {
    let status: PermissionsManager.Status

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
        switch status {
        case .authorized: .green
        case .denied:     .orange
        case .unknown:    .gray
        }
    }
    private var label: String {
        switch status {
        case .authorized: "Granted"
        case .denied:     "Not granted"
        case .unknown:    "Checking…"
        }
    }
}

private struct FeatureRow: View {
    let feature: PermissionsCatalog.Feature
    let status: PermissionsManager.Status

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: indicatorSymbol)
                .foregroundStyle(indicatorColor)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(feature.name)
                        .font(.callout.weight(.medium))
                    if !feature.isRequired {
                        Text("(optional)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(feature.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    /// Resolved enabled/disabled for *this* feature under *this* permission.
    /// Optional features stay green when the permission is missing because
    /// the feature still works in some modes (e.g. drops into non-protected
    /// folders without FDA).
    private var isEffectivelyEnabled: Bool {
        switch status {
        case .authorized: true
        case .denied:     !feature.isRequired
        case .unknown:    true // optimistic until we know
        }
    }

    private var indicatorColor: Color { isEffectivelyEnabled ? .green : .red }
    private var indicatorSymbol: String { isEffectivelyEnabled ? "checkmark.circle.fill" : "xmark.circle.fill" }
}
