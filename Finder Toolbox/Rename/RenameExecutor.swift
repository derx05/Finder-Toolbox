import Foundation

actor RenameExecutor {
    private let bridge = FinderBridge()

    /// A fully-resolved rename plan: every selected item plus, in `.recursive`
    /// mode, every (non-hidden) descendant, with conflict-resolved target names
    /// and the path each item will live at after the whole batch completes.
    struct Plan: Sendable {
        let renames: [PlannedRename]
        /// File-only count (excludes directory self-renames). Used for the
        /// threshold confirmation prompt in recursive mode.
        let fileCount: Int
        /// Folder-self count (folders in the selection or descended into).
        let folderCount: Int

        var isEmpty: Bool { renames.isEmpty }
    }

    struct PlannedRename: Sendable {
        let originalURL: URL
        let newName: String
        /// Path the item will occupy after every rename in the batch has run.
        /// Used to build undo records — survives ancestor folder renames.
        let finalURL: URL
        let isDirectory: Bool
    }

    /// Plans without executing. Lets the caller display a confirmation
    /// (file count) before committing.
    func plan(folderMode: FolderMode) async throws -> Plan {
        let urls = try await bridge.selectedFileURLs()
        return buildPlan(from: urls, folderMode: folderMode)
    }

    func execute(plan: Plan) async -> BatchSummary {
        var renames: [(from: URL, to: String)] = []
        var outcomes: [RenameOutcome] = []

        for item in plan.renames {
            if item.originalURL.lastPathComponent == item.newName {
                outcomes.append(.skipped(item.originalURL, reason: .alreadyCanonical))
                continue
            }
            renames.append((from: item.originalURL, to: item.newName))
        }

        let executed = await bridge.batchRename(renames)

        // Rewrite each .renamed outcome's "to" URL to the final post-batch
        // path. The bridge can't compute this because it doesn't know which
        // ancestor folders are also being renamed.
        let finalByOriginal: [URL: URL] = Dictionary(
            uniqueKeysWithValues: plan.renames.map { ($0.originalURL, $0.finalURL) }
        )
        for outcome in executed {
            switch outcome {
            case .renamed(let from, _):
                outcomes.append(.renamed(from: from, to: finalByOriginal[from] ?? from))
            default:
                outcomes.append(outcome)
            }
        }
        return BatchSummary(outcomes: outcomes)
    }

    func reverseRename(_ records: [RenameRecord]) async -> BatchSummary {
        // Same deepest-first order as the forward batch: each record's
        // `renamedURL` is the final post-batch path, so renaming descendants
        // first leaves ancestor paths valid until their turn comes.
        let sorted = records.sorted { lhs, rhs in
            lhs.renamedURL.pathComponents.count > rhs.renamedURL.pathComponents.count
        }
        let renames = sorted.map { (from: $0.renamedURL, to: $0.originalName) }
        let outcomes = await bridge.batchRename(renames)
        return BatchSummary(outcomes: outcomes)
    }

    // MARK: - Plan construction

    private func buildPlan(from selection: [URL], folderMode: FolderMode) -> Plan {
        var items: [(url: URL, isDir: Bool)] = []
        var seenPaths = Set<String>()

        for url in selection {
            let path = url.path
            guard !seenPaths.contains(path) else { continue }
            seenPaths.insert(path)

            let isDir = isDirectory(url)
            items.append((url, isDir))

            if isDir && folderMode == .recursive {
                for descendant in descendants(of: url) {
                    if seenPaths.insert(descendant.url.path).inserted {
                        items.append(descendant)
                    }
                }
            }
        }

        // Deepest-first: a child must rename before its parent, otherwise the
        // child's parent-path reference becomes stale mid-batch.
        items.sort { $0.url.pathComponents.count > $1.url.pathComponents.count }

        var newNamesByPath: [String: String] = [:]
        var claimedByParent: [String: Set<String>] = [:]
        var fileCount = 0
        var folderCount = 0

        for item in items {
            if item.isDir { folderCount += 1 } else { fileCount += 1 }

            let desired = canonicalName(for: item.url)
            let parentURL = item.url.deletingLastPathComponent()
            let parentPath = parentURL.path

            if desired == item.url.lastPathComponent {
                newNamesByPath[item.url.path] = desired
                claimedByParent[parentPath, default: []].insert(desired)
                continue
            }

            let resolved = resolveConflict(
                target: desired,
                in: parentURL,
                claimedNames: claimedByParent[parentPath] ?? []
            )
            newNamesByPath[item.url.path] = resolved
            claimedByParent[parentPath, default: []].insert(resolved)
        }

        // Compute the final post-batch URL by translating ancestor renames.
        var planned: [PlannedRename] = []
        planned.reserveCapacity(items.count)
        for item in items {
            let newName = newNamesByPath[item.url.path] ?? item.url.lastPathComponent
            let parent = item.url.deletingLastPathComponent().path
            let translatedParent = translatedPath(parent, renames: newNamesByPath)
            let final = URL(
                fileURLWithPath: (translatedParent as NSString).appendingPathComponent(newName)
            )
            planned.append(PlannedRename(
                originalURL: item.url,
                newName: newName,
                finalURL: final,
                isDirectory: item.isDir
            ))
        }

        return Plan(renames: planned, fileCount: fileCount, folderCount: folderCount)
    }

    private func descendants(of folder: URL) -> [(url: URL, isDir: Bool)] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }

        var out: [(url: URL, isDir: Bool)] = []
        while let url = enumerator.nextObject() as? URL {
            // Skip hidden items: dotfiles and .DS_Store are system noise, not
            // user content, and renaming them tends to upset Finder.
            if url.lastPathComponent.hasPrefix(".") {
                if isDirectory(url) { enumerator.skipDescendants() }
                continue
            }
            out.append((url, isDirectory(url)))
        }
        return out
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return isDir.boolValue
    }

    /// Walks up `path`, replacing each component whose original path appears
    /// in `renames` with its new name. Lets us derive an item's final
    /// post-batch path even when one of its ancestor folders is also renamed.
    private func translatedPath(_ path: String, renames: [String: String]) -> String {
        let ns = path as NSString
        let parent = ns.deletingLastPathComponent
        let leaf: String = {
            if let renamed = renames[path] { return renamed }
            return ns.lastPathComponent
        }()
        if parent.isEmpty || parent == path {
            return leaf.isEmpty ? path : leaf
        }
        let translatedParent = translatedPath(parent, renames: renames)
        return (translatedParent as NSString).appendingPathComponent(leaf)
    }

    // MARK: - Naming

    private func canonicalName(for url: URL) -> String {
        let ext = url.pathExtension
        var stem = url.deletingPathExtension().lastPathComponent

        if UserDefaults.standard.bool(forKey: DefaultsKeys.cleanupTrimStem) {
            stem = stem.trimmingCharacters(in: .whitespaces)
        }

        // .eml: use the date from the email headers rather than the filename or today.
        if ext.lowercased() == "eml",
           UserDefaults.standard.bool(forKey: DefaultsKeys.emlUseDateHeader),
           let emailDate = EmlDateExtractor.extractDate(from: url) {
            // Strip any existing date prefix from the stem so we don't double-date.
            let remainder = DateDetector.detect(in: stem)?.remainder ?? stem
            return FilenameBuilder.canonical(date: emailDate, remainder: remainder, extension: ext)
        }

        if let detected = DateDetector.detect(in: stem) {
            return FilenameBuilder.canonical(date: detected.date, remainder: detected.remainder, extension: ext)
        }
        return FilenameBuilder.canonical(date: FilenameBuilder.todayComponents(), remainder: stem, extension: ext)
    }

    private func resolveConflict(
        target: String,
        in directory: URL,
        claimedNames: Set<String>
    ) -> String {
        let exists: (String) -> Bool = { name in
            if claimedNames.contains(name) { return true }
            let url = directory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path)
        }
        if !exists(target) { return target }

        let ext = (target as NSString).pathExtension
        let base = (target as NSString).deletingPathExtension

        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            if !exists(candidate) { return candidate }
            counter += 1
        }
    }
}
