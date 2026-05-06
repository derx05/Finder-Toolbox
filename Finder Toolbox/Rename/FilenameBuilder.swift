import Foundation

enum FilenameBuilder {
    nonisolated static func canonical(date: DateComponents, remainder: String, extension ext: String) -> String {
        let y = date.year ?? 0
        let m = date.month ?? 0
        let d = date.day ?? 0
        let datePart = String(format: "%04d-%02d-%02d", y, m, d)

        let extTrimmed = ext.trimmingCharacters(in: .whitespaces)

        switch (remainder.isEmpty, extTrimmed.isEmpty) {
        case (true, true):
            return datePart
        case (true, false):
            return "\(datePart).\(extTrimmed)"
        case (false, true):
            return "\(datePart) \(remainder)"
        case (false, false):
            return "\(datePart) \(remainder).\(extTrimmed)"
        }
    }

    nonisolated static func todayComponents() -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.dateComponents([.year, .month, .day], from: Date())
    }
}
