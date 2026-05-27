import Foundation

/// How to interpret numeric dates whose order is ambiguous (e.g. "12-05-2012"
/// could be day-month-year or month-day-year). Affects the `DateDetector`
/// generic patterns — the per-style `makeDetectorEntry()` already disambiguates
/// when the output format itself fixes the order.
///
/// Defaults to `.dayFirst` (DD-MM-YYYY) — matches most non-US locales and the
/// only locale where `MM-DD-YYYY` is dominant is en_US.
nonisolated enum DateAmbiguityOrder: String, CaseIterable, Sendable {
    case dayFirst   // DD-MM-YYYY
    case monthFirst // MM-DD-YYYY

    static let `default`: DateAmbiguityOrder = .dayFirst

    static func current() -> DateAmbiguityOrder {
        guard let raw = UserDefaults.standard.string(forKey: DefaultsKeys.dateAmbiguityOrder),
              let value = DateAmbiguityOrder(rawValue: raw) else {
            return .default
        }
        return value
    }

    var displayName: String {
        switch self {
        case .dayFirst:   return "Day first (DD-MM-YYYY)"
        case .monthFirst: return "Month first (MM-DD-YYYY)"
        }
    }
}
