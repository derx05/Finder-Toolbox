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
        /// PDFs whose date couldn't be resolved silently. `AppController`
        /// drives the user prompt against this list and then calls
        /// `applyPdfResolutions` to finalize the plan before `execute`.
        let pdfDecisions: [PdfPendingDecision]

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
        var pdfDecisions: [PdfPendingDecision] = []

        for item in items {
            if item.isDir { folderCount += 1 } else { fileCount += 1 }

            let desired = canonicalName(for: item.url, pdfDecisions: &pdfDecisions)
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

        return Plan(
            renames: planned,
            fileCount: fileCount,
            folderCount: folderCount,
            pdfDecisions: pdfDecisions
        )
    }

    /// Rebuild a plan with chosen dates substituted in for previously
    /// unresolved PDFs. Callers obtain `resolutions` by running the
    /// `PdfConflictDialog` (or applying the user's settings silently) over
    /// `plan.pdfDecisions` and mapping each original URL to the chosen
    /// `DateComponents`. Items not in the dict keep their original name.
    func applyPdfResolutions(plan: Plan, resolutions: [URL: DateComponents]) -> Plan {
        guard !resolutions.isEmpty else { return plan }

        // Index decisions for cheap lookup of the cached remainder/ext.
        let decisionsByURL: [URL: PdfPendingDecision] = Dictionary(
            uniqueKeysWithValues: plan.pdfDecisions.map { ($0.originalURL, $0) }
        )

        // Reserved-names map keyed by parent dir, seeded with the names
        // every *other* item is already claiming. As we re-resolve, we
        // remove the old name first so the same item doesn't appear to
        // conflict with itself.
        var claimedByParent: [String: Set<String>] = [:]
        for item in plan.renames {
            let parent = item.originalURL.deletingLastPathComponent().path
            claimedByParent[parent, default: []].insert(item.newName)
        }

        var updated = plan.renames
        for (index, item) in updated.enumerated() {
            guard let chosen = resolutions[item.originalURL],
                  let decision = decisionsByURL[item.originalURL] else { continue }

            let parent = item.originalURL.deletingLastPathComponent().path
            var claims = claimedByParent[parent] ?? []
            claims.remove(item.newName)

            let target = FilenameBuilder.canonical(
                date: chosen,
                remainder: decision.remainder,
                extension: decision.ext
            )
            let resolved = resolveConflict(
                target: target,
                in: item.originalURL.deletingLastPathComponent(),
                claimedNames: claims
            )

            claims.insert(resolved)
            claimedByParent[parent] = claims

            // The final URL only changes leaf-side; ancestor folders aren't
            // PDFs so their translated path stays the same.
            let translatedParent = (item.finalURL.deletingLastPathComponent().path as NSString)
            let finalURL = URL(fileURLWithPath: translatedParent.appendingPathComponent(resolved))

            updated[index] = PlannedRename(
                originalURL: item.originalURL,
                newName: resolved,
                finalURL: finalURL,
                isDirectory: item.isDirectory
            )
        }

        return Plan(
            renames: updated,
            fileCount: plan.fileCount,
            folderCount: plan.folderCount,
            pdfDecisions: []  // resolutions consumed
        )
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

    private func canonicalName(for url: URL, pdfDecisions: inout [PdfPendingDecision]) -> String {
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

        // .pdf: invoice-date extraction. May enqueue a decision for the
        // user when the document yields ambiguous candidates.
        if ext.lowercased() == "pdf",
           UserDefaults.standard.bool(forKey: DefaultsKeys.pdfUseContentDate) {
            let remainder = DateDetector.detect(in: stem)?.remainder ?? stem
            if let name = canonicalPdfName(
                url: url,
                remainder: remainder,
                extension: ext,
                decisions: &pdfDecisions
            ) {
                return name
            }
        }

        if let detected = DateDetector.detect(in: stem) {
            return FilenameBuilder.canonical(date: detected.date, remainder: detected.remainder, extension: ext)
        }
        return FilenameBuilder.canonical(date: FilenameBuilder.todayComponents(), remainder: stem, extension: ext)
    }

    private func canonicalPdfName(
        url: URL,
        remainder: String,
        extension ext: String,
        decisions: inout [PdfPendingDecision]
    ) -> String? {
        let allowOCR = UserDefaults.standard.bool(forKey: DefaultsKeys.pdfUseOcrFallback)
        let extracted = PdfDateExtractor.extract(from: url, allowOCR: allowOCR)
        let tolerance = max(0, UserDefaults.standard.integer(forKey: DefaultsKeys.pdfConflictToleranceDays))

        switch (extracted.heuristic, extracted.metadata) {
        case (.some(let heuristic), .some(let metadata)):
            if Self.daysBetween(heuristic, metadata) <= tolerance {
                // Effectively agree — heuristic wins silently.
                return FilenameBuilder.canonical(date: heuristic, remainder: remainder, extension: ext)
            }
            switch PdfConflictBehavior.current() {
            case .preferHeuristic:
                return FilenameBuilder.canonical(date: heuristic, remainder: remainder, extension: ext)
            case .preferMetadata:
                return FilenameBuilder.canonical(date: metadata, remainder: remainder, extension: ext)
            case .ask:
                decisions.append(PdfPendingDecision(
                    originalURL: url, kind: .conflict,
                    heuristic: heuristic, metadata: metadata,
                    remainder: remainder, ext: ext
                ))
                // Working default until the dialog answers. Most invoice
                // documents have the right answer in the body, not the
                // metadata, so heuristic is the lower-risk placeholder.
                return FilenameBuilder.canonical(date: heuristic, remainder: remainder, extension: ext)
            }

        case (.some(let heuristic), .none):
            return FilenameBuilder.canonical(date: heuristic, remainder: remainder, extension: ext)

        case (.none, .some(let metadata)):
            switch PdfNoDateBehavior.current() {
            case .metadata:
                return FilenameBuilder.canonical(date: metadata, remainder: remainder, extension: ext)
            case .today:
                return FilenameBuilder.canonical(date: FilenameBuilder.todayComponents(), remainder: remainder, extension: ext)
            case .ask:
                decisions.append(PdfPendingDecision(
                    originalURL: url, kind: .noDate,
                    heuristic: nil, metadata: metadata,
                    remainder: remainder, ext: ext
                ))
                return FilenameBuilder.canonical(date: metadata, remainder: remainder, extension: ext)
            }

        case (.none, .none):
            return nil  // Fall through to filename-stem detection / today.
        }
    }

    nonisolated private static func daysBetween(_ a: DateComponents, _ b: DateComponents) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let dateA = cal.date(from: a), let dateB = cal.date(from: b) else { return Int.max }
        let comps = cal.dateComponents([.day], from: dateA, to: dateB)
        return abs(comps.day ?? 0)
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
