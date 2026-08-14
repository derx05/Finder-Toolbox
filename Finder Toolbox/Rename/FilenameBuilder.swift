import Foundation

enum FilenameBuilder {
    /// APFS caps filenames at 255 UTF-8 bytes, HFS+ at 255 UTF-16 units.
    /// A string's UTF-8 count is always ≥ its UTF-16 count, so clamping
    /// UTF-8 to 255 satisfies both.
    nonisolated static let maxFilenameBytes = 255

    nonisolated static func canonical(date: DateComponents, remainder: String, extension ext: String) -> String {
        let datePart = DateFormatStyle.current().format(date)

        let extTrimmed = ext.trimmingCharacters(in: .whitespaces)

        switch (remainder.isEmpty, extTrimmed.isEmpty) {
        case (true, true):
            return datePart
        case (true, false):
            return "\(datePart).\(extTrimmed)"
        case (false, true):
            return fitting(stem: "\(datePart) \(remainder)", ext: "")
        case (false, false):
            return fitting(stem: "\(datePart) \(remainder)", ext: extTrimmed)
        }
    }

    /// Assembles `stem + suffix + "." + ext`, truncating `stem` if needed so
    /// the whole name fits `maxFilenameBytes`. Only the stem is shortened —
    /// the suffix (conflict counter) and extension always survive intact.
    /// The date prefix at the head of the stem is short enough that
    /// truncation from the end can only ever eat into the remainder.
    nonisolated static func fitting(stem: String, suffix: String = "", ext: String) -> String {
        let extPart = ext.isEmpty ? "" : ".\(ext)"
        let budget = maxFilenameBytes - suffix.utf8.count - extPart.utf8.count
        var stem = stem
        if stem.utf8.count > budget {
            stem = truncated(stem, toUTF8Bytes: max(0, budget))
        }
        return stem + suffix + extPart
    }

    /// Cuts on Character boundaries so composed emoji/umlauts aren't split
    /// mid-scalar, then drops trailing separator noise left at the cut.
    nonisolated private static func truncated(_ s: String, toUTF8Bytes limit: Int) -> String {
        guard s.utf8.count > limit else { return s }
        var out = ""
        var used = 0
        for ch in s {
            let width = String(ch).utf8.count
            if used + width > limit { break }
            out.append(ch)
            used += width
        }
        while let last = out.last, " -_.".contains(last) {
            out.removeLast()
        }
        return out
    }

    nonisolated static func todayComponents() -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.dateComponents([.year, .month, .day], from: Date())
    }
}
