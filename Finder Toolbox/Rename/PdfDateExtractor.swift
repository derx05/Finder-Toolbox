import Foundation
import PDFKit
import Vision
import CoreGraphics

/// Result of inspecting a PDF for a date suitable for use as the rename
/// prefix. The extractor returns *both* candidates it could find (the
/// heuristic text-scan and the embedded PDF metadata creation date) and
/// leaves reconciliation to the caller — `RenameExecutor` consults the
/// user's settings to decide which one wins or whether to prompt.
struct PdfDateExtractionResult: Sendable {
    let heuristic: DateComponents?
    let metadata: DateComponents?
    /// True when the heuristic ran against OCR output rather than the
    /// PDF's native text layer. Diagnostic only — surfaced nowhere yet but
    /// useful if we ever want to flag "scanned PDF, please verify" in the
    /// summary dialog.
    let ocrUsed: Bool
}

/// Reads invoice-style date information out of a PDF. Pure Foundation +
/// PDFKit + Vision; no main-actor work — call off the main thread.
enum PdfDateExtractor {

    /// Number of leading pages to read text from. Two is enough to cover
    /// invoice layouts that put the date below a logo on page 1 but spill
    /// into page 2; more would just slow down batches without helping.
    nonisolated private static let pageReadLimit = 2

    /// Minimum text length below which we assume the PDF is image-based
    /// and fall back to OCR (when allowed). Two short labels on a scanned
    /// page can produce 30-40 chars of garbage; 50 is the empirical floor.
    nonisolated private static let ocrThreshold = 50

    nonisolated static func extract(from url: URL, allowOCR: Bool) -> PdfDateExtractionResult {
        guard let document = PDFDocument(url: url) else {
            return PdfDateExtractionResult(heuristic: nil, metadata: nil, ocrUsed: false)
        }

        let metadata = metadataCreationDate(from: document)
        var text = extractText(from: document, maxPages: pageReadLimit)
        var ocrUsed = false

        if text.count < ocrThreshold, allowOCR, let ocrText = ocrFirstPage(of: document) {
            text += "\n" + ocrText
            ocrUsed = !ocrText.isEmpty
        }

        let heuristic = findInvoiceDate(in: text)
        return PdfDateExtractionResult(heuristic: heuristic, metadata: metadata, ocrUsed: ocrUsed)
    }

    // MARK: - PDFKit

    nonisolated private static func extractText(from document: PDFDocument, maxPages: Int) -> String {
        var collected = ""
        let count = min(document.pageCount, maxPages)
        for i in 0..<count {
            guard let page = document.page(at: i), let pageText = page.string else { continue }
            collected += pageText
            collected += "\n"
        }
        return collected
    }

    nonisolated private static func metadataCreationDate(from document: PDFDocument) -> DateComponents? {
        guard let attrs = document.documentAttributes,
              let date = attrs[PDFDocumentAttribute.creationDateAttribute] as? Date else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        return cal.dateComponents([.year, .month, .day], from: date)
    }

    // MARK: - OCR fallback

    nonisolated private static func ocrFirstPage(of document: PDFDocument) -> String? {
        guard let page = document.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        // 2× upsample. Good enough for invoice body text without exploding
        // memory on A3 scans.
        let scale: CGFloat = 2.0
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        guard width > 0, height > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // PDF pages draw on a white background by convention; without this
        // the scan reads as light glyphs on a transparent canvas and Vision
        // fails to lock onto baselines.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        page.draw(with: .mediaBox, to: context)

        guard let cgImage = context.makeImage() else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observations = request.results else { return nil }
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    // MARK: - Heuristic

    /// Public for testability. Runs label-anchored matching first, then
    /// falls back to the earliest plausible date in the document's upper
    /// portion. Returns `nil` only when nothing date-shaped was found.
    nonisolated static func findInvoiceDate(in text: String) -> DateComponents? {
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()

        // Labels ordered most-specific-first. "Rechnungsdatum" wins over
        // bare "Datum" when both appear, because bare "Datum" tends to
        // label something else (Lieferdatum, Kontoauszugsdatum, etc.).
        let labels = [
            "rechnungsdatum",
            "belegdatum",
            "lieferdatum",
            "leistungsdatum",
            "rechnung vom",
            "invoice date",
            "bill date",
            "issue date",
            "date of issue",
            "issued on",
            "datum",
            "issued",
            "date:"
        ]

        for label in labels {
            var cursor = lower.startIndex
            while let range = lower.range(of: label, range: cursor..<lower.endIndex) {
                // 80-char window past the label captures both inline
                // ("Rechnungsdatum: 03.05.2024") and stacked-cell layouts
                // ("Rechnungsdatum\n03.05.2024") without drifting into
                // unrelated fields.
                let endLimit = lower.index(range.upperBound, offsetBy: 80, limitedBy: lower.endIndex) ?? lower.endIndex
                let window = String(text[range.upperBound..<endLimit])
                if let found = firstDate(in: window) { return found }
                cursor = range.upperBound
            }
        }

        // No label hit — try the document's opening text. Invoices that
        // omit the label still tend to print the date prominently in the
        // top section, often near the addressee block.
        let upper = String(text.prefix(2000))
        return firstDate(in: upper)
    }

    nonisolated private static func firstDate(in text: String) -> DateComponents? {
        for matcher in matchers {
            if let date = matcher(text) { return date }
        }
        return nil
    }

    nonisolated private static let matchers: [@Sendable (String) -> DateComponents?] = {
        var built: [@Sendable (String) -> DateComponents?] = []

        // 1. YYYY-MM-DD / YYYY.MM.DD / YYYY/MM/DD — unambiguous, year first.
        built.append(numericMatcher(
            pattern: #"\b(\d{4})[-./](\d{1,2})[-./](\d{1,2})\b"#,
            order: .ymd
        ))

        // 2. DD.MM.YYYY / DD/MM/YYYY / DD-MM-YYYY — EU style, day first.
        built.append(numericMatcher(
            pattern: #"\b(\d{1,2})[./-](\d{1,2})[./-](\d{4})\b"#,
            order: .dmy
        ))

        // 3. DD.MM.YY — EU two-digit-year style. Comes last in the numeric
        // matchers so a four-digit-year date isn't truncated to its first
        // two digits by a greedier rule.
        built.append(numericMatcher(
            pattern: #"\b(\d{1,2})[./-](\d{1,2})[./-](\d{2})\b"#,
            order: .dmyShort
        ))

        // 4. Spelled-out month names ("May 3, 2024", "3 May 2024",
        // "3. Mai 2024"). NSDataDetector handles locale variations,
        // including German month names on a German system.
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            built.append { text in
                let ns = text as NSString
                let range = NSRange(location: 0, length: ns.length)
                guard let match = detector.firstMatch(in: text, options: [], range: range),
                      let date = match.date else { return nil }
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = TimeZone.current
                return cal.dateComponents([.year, .month, .day], from: date)
            }
        }

        return built
    }()

    private enum NumericOrder { case ymd, dmy, dmyShort }

    nonisolated private static func numericMatcher(pattern: String, order: NumericOrder) -> @Sendable (String) -> DateComponents? {
        let regex = try! NSRegularExpression(pattern: pattern)
        return { text in
            let ns = text as NSString
            // Walk all matches — the first regex hit may be a phone number
            // or order ID that happens to fit the shape. Returning the
            // first *valid* date avoids spurious matches without losing
            // the "earliest wins" property.
            var index = 0
            while index < ns.length {
                guard let match = regex.firstMatch(
                    in: text,
                    range: NSRange(location: index, length: ns.length - index)
                ), match.numberOfRanges >= 4 else { return nil }

                let a = Int(ns.substring(with: match.range(at: 1))) ?? -1
                let b = Int(ns.substring(with: match.range(at: 2))) ?? -1
                let c = Int(ns.substring(with: match.range(at: 3))) ?? -1

                let candidate: DateComponents? = {
                    switch order {
                    case .ymd:      return components(y: a, m: b, d: c)
                    case .dmy:      return components(y: c, m: b, d: a)
                    case .dmyShort: return components(y: expandShortYear(c), m: b, d: a)
                    }
                }()

                if let candidate { return candidate }
                index = match.range.location + match.range.length
            }
            return nil
        }
    }

    nonisolated private static func expandShortYear(_ yy: Int) -> Int {
        yy >= 70 ? 1900 + yy : 2000 + yy
    }

    nonisolated private static func components(y: Int, m: Int, d: Int) -> DateComponents? {
        guard m >= 1, m <= 12, d >= 1, d <= 31, y >= 1900, y <= 2100 else { return nil }
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = cal.date(from: dc) else { return nil }
        let recheck = cal.dateComponents([.year, .month, .day], from: date)
        guard recheck.year == y, recheck.month == m, recheck.day == d else { return nil }
        return dc
    }
}
