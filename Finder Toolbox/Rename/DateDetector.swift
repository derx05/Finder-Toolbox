import Foundation

struct DateDetectionResult: Sendable {
    let date: DateComponents  // .year, .month, .day populated
    let remainder: String     // stem text after the date+separator, trimmed of leading spaces/dashes/underscores
}

enum DateDetector {
    private struct PatternEntry: Sendable {
        let regex: NSRegularExpression
        let extract: @Sendable (_ groups: [String]) -> (year: Int, month: Int, day: Int)?
    }

    nonisolated private static let patterns: [PatternEntry] = buildPatterns()

    nonisolated static func detect(in stem: String) -> DateDetectionResult? {
        let nsStr = stem as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        for entry in patterns {
            guard let match = entry.regex.firstMatch(in: stem, range: fullRange) else { continue }

            let groups = (1..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : nsStr.substring(with: r)
            }

            guard let (y, m, d) = entry.extract(groups) else { continue }

            var comps = DateComponents()
            comps.year = y; comps.month = m; comps.day = d
            guard isValidDate(comps) else { continue }

            let matchEnd = match.range.location + match.range.length
            let rest = matchEnd < nsStr.length ? nsStr.substring(from: matchEnd) : ""
            let remainder = rest.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))

            return DateDetectionResult(date: comps, remainder: remainder)
        }
        return nil
    }

    // MARK: - Helpers

    nonisolated private static func isValidDate(_ comps: DateComponents) -> Bool {
        guard let y = comps.year, let m = comps.month, let d = comps.day,
              m >= 1, m <= 12, d >= 1, d <= 31 else { return false }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: comps) else { return false }
        let back = cal.dateComponents([.year, .month, .day], from: date)
        return back.year == y && back.month == m && back.day == d
    }

    nonisolated private static func fullYear(from twoDigit: Int) -> Int {
        twoDigit >= 70 ? 1900 + twoDigit : 2000 + twoDigit
    }

    nonisolated private static func buildPatterns() -> [PatternEntry] {
        func regex(_ pattern: String) -> NSRegularExpression {
            // All patterns are anchored to start of string.
            try! NSRegularExpression(pattern: "^" + pattern + "[ _-]?")
        }

        return [
            // 1. YYYY-MM-DD
            PatternEntry(regex: regex(#"(\d{4})-(\d{2})-(\d{2})"#)) { g in
                guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (y, m, d)
            },
            // 2. YYYYMMDD (year 1900–2099)
            PatternEntry(regex: regex(#"(\d{4})(\d{2})(\d{2})"#)) { g in
                guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]),
                      y >= 1900, y <= 2099 else { return nil }
                return (y, m, d)
            },
            // 3. DD.MM.YYYY
            PatternEntry(regex: regex(#"(\d{2})\.(\d{2})\.(\d{4})"#)) { g in
                guard let d = Int(g[0]), let m = Int(g[1]), let y = Int(g[2]) else { return nil }
                return (y, m, d)
            },
            // 4. DD.MM.YY
            PatternEntry(regex: regex(#"(\d{2})\.(\d{2})\.(\d{2})"#)) { g in
                guard let d = Int(g[0]), let m = Int(g[1]), let yy = Int(g[2]) else { return nil }
                return (fullYear(from: yy), m, d)
            },
            // 5. YY-MM-DD
            PatternEntry(regex: regex(#"(\d{2})-(\d{2})-(\d{2})"#)) { g in
                guard let yy = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (fullYear(from: yy), m, d)
            },
            // 6. YYMMDD
            PatternEntry(regex: regex(#"(\d{2})(\d{2})(\d{2})"#)) { g in
                guard let yy = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (fullYear(from: yy), m, d)
            },
        ]
    }
}
