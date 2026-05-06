import Foundation

actor RenameExecutor {
    private let bridge = FinderBridge()

    func run() async -> BatchSummary {
        do {
            let urls = try await bridge.selectedFileURLs()

            var renames: [(from: URL, to: String)] = []
            var outcomes: [RenameOutcome] = []

            for url in urls {
                let target = canonicalName(for: url)
                if url.lastPathComponent == target {
                    outcomes.append(.skipped(url, reason: .alreadyCanonical))
                    continue
                }
                let resolved = resolveConflict(target: target, in: url.deletingLastPathComponent())
                renames.append((from: url, to: resolved))
            }

            let renameOutcomes = await bridge.batchRename(renames)
            outcomes.append(contentsOf: renameOutcomes)

            return BatchSummary(outcomes: outcomes)

        } catch FinderBridgeError.noSelection {
            return BatchSummary(outcomes: [])
        } catch FinderBridgeError.automationDenied {
            await MainActor.run { PermissionsManager.shared.markDenied() }
            return BatchSummary(outcomes: [])
        } catch {
            return BatchSummary(outcomes: [
                .failed(URL(fileURLWithPath: "/"), error: error.localizedDescription)
            ])
        }
    }

    // MARK: - Private

    private func canonicalName(for url: URL) -> String {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        if let detected = DateDetector.detect(in: stem) {
            return FilenameBuilder.canonical(date: detected.date, remainder: detected.remainder, extension: ext)
        }
        return FilenameBuilder.canonical(date: FilenameBuilder.todayComponents(), remainder: stem, extension: ext)
    }

    private func resolveConflict(target: String, in directory: URL) -> String {
        let targetURL = directory.appendingPathComponent(target)
        guard FileManager.default.fileExists(atPath: targetURL.path) else { return target }

        let ext = (target as NSString).pathExtension
        let base = (target as NSString).deletingPathExtension

        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
            counter += 1
        }
    }
}
