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

    nonisolated static func detect(in stem: String) -> DateDetectionResult? {
        let nsStr = stem as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        // Pattern priority — earlier entries win:
        //   1. The exact shape the output style emits, so files we wrote
        //      round-trip cleanly and don't fall into a generic 2-digit-year
        //      pattern that would mis-parse them.
        //   2. Generic 4-digit-year patterns. These must precede 2-digit-year
        //      ones — otherwise "12-05-2012" gets eaten as YY-MM-DD = 2012-05-20
        //      leaving "12 …" as remainder (issue #20).
        //   3. Generic 2-digit-year fallbacks.
        // The ambiguity setting only flips the order interpretation for purely
        // numeric forms that could plausibly be either DD-MM or MM-DD.
        var allPatterns: [PatternEntry] = []
        if let styleEntry = DateFormatStyle.current().makeDetectorEntry() {
            allPatterns.append(PatternEntry(regex: styleEntry.regex, extract: styleEntry.extract))
        }
        allPatterns.append(contentsOf: buildPatterns(order: DateAmbiguityOrder.current()))

        for entry in allPatterns {
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

    nonisolated private static func buildPatterns(order: DateAmbiguityOrder) -> [PatternEntry] {
        func regex(_ pattern: String) -> NSRegularExpression {
            // All patterns are anchored to start of string.
            try! NSRegularExpression(pattern: "^" + pattern + "[ _-]?")
        }

        // For two ambiguous two-digit fields followed by a 4-digit year, the
        // user setting picks which field is day vs. month. The 4-digit-year
        // patterns come BEFORE any 2-digit-year fallback so dates like
        // "12-05-2012" don't get eaten as YY-MM-DD.
        let ambig: PatternEntry = {
            switch order {
            case .dayFirst:
                return PatternEntry(regex: regex(#"(\d{2})-(\d{2})-(\d{4})"#)) { g in
                    guard let d = Int(g[0]), let m = Int(g[1]), let y = Int(g[2]) else { return nil }
                    return (y, m, d)
                }
            case .monthFirst:
                return PatternEntry(regex: regex(#"(\d{2})-(\d{2})-(\d{4})"#)) { g in
                    guard let m = Int(g[0]), let d = Int(g[1]), let y = Int(g[2]) else { return nil }
                    return (y, m, d)
                }
            }
        }()

        // Dotted form: pure-numeric DD.MM.YYYY is overwhelmingly European, but
        // honor the ambiguity setting for consistency.
        let dotted: PatternEntry = {
            switch order {
            case .dayFirst:
                return PatternEntry(regex: regex(#"(\d{2})\.(\d{2})\.(\d{4})"#)) { g in
                    guard let d = Int(g[0]), let m = Int(g[1]), let y = Int(g[2]) else { return nil }
                    return (y, m, d)
                }
            case .monthFirst:
                return PatternEntry(regex: regex(#"(\d{2})\.(\d{2})\.(\d{4})"#)) { g in
                    guard let m = Int(g[0]), let d = Int(g[1]), let y = Int(g[2]) else { return nil }
                    return (y, m, d)
                }
            }
        }()

        let dottedShortYear: PatternEntry = {
            switch order {
            case .dayFirst:
                return PatternEntry(regex: regex(#"(\d{2})\.(\d{2})\.(\d{2})"#)) { g in
                    guard let d = Int(g[0]), let m = Int(g[1]), let yy = Int(g[2]) else { return nil }
                    return (fullYear(from: yy), m, d)
                }
            case .monthFirst:
                return PatternEntry(regex: regex(#"(\d{2})\.(\d{2})\.(\d{2})"#)) { g in
                    guard let m = Int(g[0]), let d = Int(g[1]), let yy = Int(g[2]) else { return nil }
                    return (fullYear(from: yy), m, d)
                }
            }
        }()

        return [
            // 4-digit-year, unambiguous shape: YYYY-MM-DD
            PatternEntry(regex: regex(#"(\d{4})-(\d{2})-(\d{2})"#)) { g in
                guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (y, m, d)
            },
            // 4-digit-year compact: YYYYMMDD (year 1900–2099)
            PatternEntry(regex: regex(#"(\d{4})(\d{2})(\d{2})"#)) { g in
                guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]),
                      y >= 1900, y <= 2099 else { return nil }
                return (y, m, d)
            },
            // 4-digit-year YYYY_MM_DD (underscore separators)
            PatternEntry(regex: regex(#"(\d{4})_(\d{2})_(\d{2})"#)) { g in
                guard let y = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (y, m, d)
            },
            // 4-digit-year ambiguous DD-MM-YYYY / MM-DD-YYYY (setting picks)
            ambig,
            // 4-digit-year dotted (same setting)
            dotted,
            // 2-digit-year fallbacks below — must come after every 4-digit-year
            // pattern. Otherwise "12-05-2012" → "12-05-20" gets matched first.
            dottedShortYear,
            // YY-MM-DD
            PatternEntry(regex: regex(#"(\d{2})-(\d{2})-(\d{2})"#)) { g in
                guard let yy = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (fullYear(from: yy), m, d)
            },
            // YYMMDD
            PatternEntry(regex: regex(#"(\d{2})(\d{2})(\d{2})"#)) { g in
                guard let yy = Int(g[0]), let m = Int(g[1]), let d = Int(g[2]) else { return nil }
                return (fullYear(from: yy), m, d)
            },
        ]
    }
}
