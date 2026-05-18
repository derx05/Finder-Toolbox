import SwiftUI
import AppKit

/// "About" panel: app identity, update toggles (placeholder), and quit/links row.
struct AboutPage: View {
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    private let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    private let year    = String(format: "%d", Calendar.current.component(.year, from: Date()))

    @AppStorage(DefaultsKeys.updatesAutoCheck)    private var autoCheck: Bool    = false
    @AppStorage(DefaultsKeys.updatesAutoDownload) private var autoDownload: Bool = false
    @AppStorage(DefaultsKeys.updatesLastChecked)  private var lastCheckedRaw: Double = 0

    private var lastCheckedLabel: String {
        guard lastCheckedRaw > 0 else { return "Never" }
        return Date(timeIntervalSince1970: lastCheckedRaw)
            .formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 28) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 128, height: 128)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Finder Toolbox")
                            .font(.system(size: 32, weight: .bold))

                        Text("Version \(version) (\(build))")
                            .font(.title3)
                            .foregroundStyle(.secondary)

                        Text("© \(year) Daniel Ammann")
                            .font(.body)
                            .foregroundStyle(.tertiary)

                        if BuildConfiguration.isDebug {
                            Text("Debug Build — development session")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)

                Toggle("Automatically check for updates", isOn: $autoCheck)
                    .toggleStyle(.switch)

                Toggle("Automatically download updates", isOn: $autoDownload)
                    .toggleStyle(.switch)

                HStack {
                    Button("Check for Updates") {}
                        .disabled(true)
                    Spacer()
                    Text("Last checked: \(lastCheckedLabel)")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }

            Section {
                HStack {
                    Button("Quit Finder Toolbox", role: .destructive) {
                        DockModeManager.shared.explicitQuit()
                    }
                    .buttonStyle(HoverButtonStyle(tint: .red))

                    Spacer()

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/danielammann/finder-toolbox")!)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .imageScale(.small)
                            Text("GitHub")
                        }
                    }
                    .buttonStyle(HoverButtonStyle(tint: .secondary))
                }
            }
        }
        .formStyle(.grouped)
    }
}
