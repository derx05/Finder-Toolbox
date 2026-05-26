import Foundation

/// User-selectable output format for the date prefix that rename batches emit.
///
/// `DateDetector` continues to recognise *every* historical format on input
/// (so files renamed under a different setting still parse). This enum only
/// controls how `FilenameBuilder` re-emits the date — plus a parse-back entry
/// point that `DateDetector` tries first, so files we render in one style get
/// recognised on the next rename pass instead of being double-prefixed.
///
/// Slashed formats (`MM/dd/yyyy`, etc.) are deliberately omitted: `/` is the
/// path separator on macOS and isn't legal in filenames. The `.system` case
/// substitutes `/` with `-` so users in slash-locales still get a sensible
/// default.
///
/// All members are `nonisolated` so the rename actor (which runs off the main
/// actor) can use them without crossing an isolation boundary.
nonisolated enum DateFormatStyle: String, CaseIterable, Sendable {
    /// Follows the user's macOS region setting (Locale.current), sanitized
    /// for filename use: `/` → `-`, and the year is always 4 digits.
    case system
    /// `2026-05-26` — ISO 8601 / RFC 3339 calendar date.
    case iso
    /// `26.05.2026` — German/Austrian/Swiss dotted.
    case dottedDE
    /// `26-05-2026` — day-first dashed.
    case dashedDE
    /// `20260526` — compact, no separators.
    case compact
    /// `2026_05_26` — underscore separators.
    case underscore

    static let `default`: DateFormatStyle = .system

    static func current() -> DateFormatStyle {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.dateFormatStyle),
              let value = DateFormatStyle(rawValue: raw) else {
            return .default
        }
        return value
    }

    /// ICU date pattern this style renders. `.system` reads the user's
    /// *customized* short-date format from System Settings → General →
    /// Language & Region → Date Format (which a `DateFormatter` with
    /// `dateStyle = .short` resolves automatically) rather than the locale's
    /// CLDR template — that way a German user who picked ISO in System
    /// Settings actually gets ISO. Then sanitizes for filename safety:
    /// `/` → `-`, and any `y`/`M`/`d` field shorter than 4/2/2 digits is
    /// padded so archive filenames stay sortable and unambiguous decades on.
    /// Everything else is a fixed pattern.
    var pattern: String {
        switch self {
        case .system:
            let df = DateFormatter()
            df.locale = Locale.autoupdatingCurrent
            df.dateStyle = .short
            var raw = df.dateFormat ?? "yyyy-MM-dd"
            raw = raw.replacingOccurrences(of: "/", with: "-")
            // Lookarounds keep us from clobbering `MMM`/`MMMM` (month names)
            // or `yyyy`; we only widen short numeric fields.
            raw = raw.replacingOccurrences(
                of: #"(?<!y)y{1,2}(?!y)"#, with: "yyyy", options: .regularExpression
            )
            raw = raw.replacingOccurrences(
                of: #"(?<!M)M{1,2}(?!M)"#, with: "MM", options: .regularExpression
            )
            raw = raw.replacingOccurrences(
                of: #"(?<!d)d{1,2}(?!d)"#, with: "dd", options: .regularExpression
            )
            return raw
        case .iso:        return "yyyy-MM-dd"
        case .dottedDE:   return "dd.MM.yyyy"
        case .dashedDE:   return "dd-MM-yyyy"
        case .compact:    return "yyyyMMdd"
        case .underscore: return "yyyy_MM_dd"
        }
    }

    /// Human-readable name for the Settings picker.
    var displayName: String {
        switch self {
        case .system:     return "Follow system region"
        case .iso:        return "ISO (YYYY-MM-DD)"
        case .dottedDE:   return "Dotted (DD.MM.YYYY)"
        case .dashedDE:   return "Dashed (DD-MM-YYYY)"
        case .compact:    return "Compact (YYYYMMDD)"
        case .underscore: return "Underscore (YYYY_MM_DD)"
        }
    }

    /// Regex + component extractor that parses exactly what this style emits,
    /// anchored to the start of a filename stem with a trailing space/dash/underscore.
    /// `DateDetector` tries this first to disambiguate US `MM-dd-yyyy` vs DE
    /// `dd-MM-yyyy` using the chosen style rather than digit heuristics, and to
    /// recognise emitted formats (`yyyy_MM_dd`, `dd-MM-yyyy`) that aren't in the
    /// generic fallback list.
    ///
    /// Returns `nil` for `.system` when the locale's pattern isn't one of the
    /// well-known shapes; the generic fallback patterns still run afterwards
    /// so detection is never worse than before.
    func makeDetectorEntry() -> (regex: NSRegularExpression, extract: @Sendable (_ groups: [String]) -> (year: Int, month: Int, day: Int)?)? {
        switch pattern {
        case "yyyy-MM-dd":
            return ( regex(#"^(\d{4})-(\d{2})-(\d{2})[ _-]?"#),
                     { g in Self.zipYMD(y: g[0], m: g[1], d: g[2]) } )
        case "yyyy_MM_dd":
            return ( regex(#"^(\d{4})_(\d{2})_(\d{2})[ _-]?"#),
                     { g in Self.zipYMD(y: g[0], m: g[1], d: g[2]) } )
        case "yyyyMMdd":
            return ( regex(#"^(\d{4})(\d{2})(\d{2})[ _-]?"#),
                     { g in Self.zipYMD(y: g[0], m: g[1], d: g[2]) } )
        case "dd.MM.yyyy":
            return ( regex(#"^(\d{2})\.(\d{2})\.(\d{4})[ _-]?"#),
                     { g in Self.zipYMD(y: g[2], m: g[1], d: g[0]) } )
        case "dd-MM-yyyy":
            return ( regex(#"^(\d{2})-(\d{2})-(\d{4})[ _-]?"#),
                     { g in Self.zipYMD(y: g[2], m: g[1], d: g[0]) } )
        case "MM-dd-yyyy":
            return ( regex(#"^(\d{2})-(\d{2})-(\d{4})[ _-]?"#),
                     { g in Self.zipYMD(y: g[2], m: g[0], d: g[1]) } )
        case "MM.dd.yyyy":
            return ( regex(#"^(\d{2})\.(\d{2})\.(\d{4})[ _-]?"#),
                     { g in Self.zipYMD(y: g[2], m: g[0], d: g[1]) } )
        default:
            return nil
        }
    }

    private func regex(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p)
    }

    private static func zipYMD(y: String, m: String, d: String) -> (year: Int, month: Int, day: Int)? {
        guard let yy = Int(y), let mm = Int(m), let dd = Int(d) else { return nil }
        return (yy, mm, dd)
    }

    /// Render `comps` (which must have `.year`, `.month`, `.day`) using this
    /// style. Returns the canonical ISO form on the unlikely chance the
    /// components don't form a valid Gregorian date.
    func format(_ comps: DateComponents) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: comps) else {
            let y = comps.year ?? 0, m = comps.month ?? 0, d = comps.day ?? 0
            return String(format: "%04d-%02d-%02d", y, m, d)
        }
        let df = DateFormatter()
        df.calendar = cal
        df.timeZone = cal.timeZone
        // `.system` reads from Locale.current; fixed patterns lock to
        // en_US_POSIX so the output is stable regardless of region.
        df.locale = self == .system ? Locale.current : Locale(identifier: "en_US_POSIX")
        df.dateFormat = pattern
        return df.string(from: date)
    }
}
