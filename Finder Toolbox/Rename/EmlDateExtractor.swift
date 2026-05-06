import Foundation

enum EmlDateExtractor {

    /// Reads the header block of an .eml file and returns date components from
    /// Delivery-date (preferred) or Date. Call off the main thread.
    nonisolated static func extractDate(from url: URL) -> DateComponents? {
        guard let headerText = readHeaders(from: url) else { return nil }
        let unfolded = unfoldHeaders(headerText)
        let rawDate = headerValue("Delivery-date", in: unfolded)
                   ?? headerValue("Date", in: unfolded)
        guard let raw = rawDate else { return nil }
        return parseRFC2822(raw)
    }

    // MARK: - Private

    nonisolated private static func readHeaders(from url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let data = fh.readData(ofLength: 8192)
        guard let text = String(data: data, encoding: .utf8)
                      ?? String(data: data, encoding: .isoLatin1) else { return nil }
        if let r = text.range(of: "\r\n\r\n") { return String(text[..<r.lowerBound]) }
        if let r = text.range(of: "\n\n")     { return String(text[..<r.lowerBound]) }
        return text
    }

    nonisolated private static func unfoldHeaders(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n\t", with: " ")
            .replacingOccurrences(of: "\r\n ", with: " ")
            .replacingOccurrences(of: "\n\t",  with: " ")
            .replacingOccurrences(of: "\n ",   with: " ")
    }

    nonisolated private static func headerValue(_ name: String, in headers: String) -> String? {
        let prefix = name.lowercased() + ":"
        for line in headers.components(separatedBy: "\n") {
            let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if stripped.lowercased().hasPrefix(prefix) {
                return String(stripped.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    nonisolated private static func parseRFC2822(_ raw: String) -> DateComponents? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // RFC 2822 date, with and without the optional day-of-week prefix.
        let formats = [
            "E, d MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z",
            "E, d MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z",
        ]
        for fmt in formats {
            formatter.dateFormat = fmt
            guard let date = formatter.date(from: s) else { continue }
            // Extract y/m/d in the timezone stated in the header so the date
            // reflects the sender's/relay's local day, not UTC.
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = offsetTimeZone(from: s) ?? TimeZone(secondsFromGMT: 0)!
            return cal.dateComponents([.year, .month, .day], from: date)
        }
        return nil
    }

    nonisolated private static func offsetTimeZone(from string: String) -> TimeZone? {
        guard let match = string.range(of: #"[+-]\d{4}"#, options: .regularExpression) else { return nil }
        let token = String(string[match])
        guard token.count == 5,
              let hours = Int(token.dropFirst().prefix(2)),
              let mins  = Int(token.suffix(2)) else { return nil }
        let sign = token.first == "+" ? 1 : -1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + mins * 60))
    }
}
