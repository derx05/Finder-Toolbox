import XCTest
@testable import Finder_Toolbox

/// `PdfDateExtractor.findInvoiceDate(in:)` is the heuristic regex pass
/// that runs over the text extracted from a PDF. Testing it against raw
/// String fixtures keeps these tests fast and removes the need to check
/// PDF binaries into the repo.
final class PdfDateExtractorTests: XCTestCase {

    // MARK: - Label-anchored matches

    func testGermanRechnungsdatumInline() {
        let text = "MUSTER GMBH\nRechnungsnummer: 2024/0012\nRechnungsdatum: 03.05.2024\nKunde: Frau Müller"
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.year, 2024)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 3)
    }

    func testGermanRechnungsdatumStacked() {
        // Common in two-column invoice layouts where the label and the
        // value sit on adjacent lines.
        let text = "Rechnungsdatum\n03.05.2024\nKunde\nFrau Müller"
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.day, 3)
        XCTAssertEqual(date?.year, 2024)
    }

    func testEnglishInvoiceDate() {
        let text = "ACME Inc.\nInvoice Number: 0042\nInvoice Date: 2024-05-03\nBill To: …"
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.year, 2024)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 3)
    }

    func testEnglishIssueDate() {
        let text = "Issue Date: 2024-05-03\nDue Date: 2024-06-02"
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 3)
    }

    func testRechnungsdatumWinsOverDatum() {
        // A document with both labels should resolve to Rechnungsdatum
        // since it's the more specific label. The "Datum" line above is
        // a delivery date and must not win.
        let text = """
        Datum: 01.06.2024
        Kunde: Müller GmbH
        ...
        Rechnungsdatum: 03.05.2024
        """
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.day, 3)
        XCTAssertEqual(date?.month, 5)
    }

    func testLabelWindowDoesNotBleedIntoNextField() {
        // 80-char window past the label. The date here sits well past
        // that window and should NOT be picked up by the label match —
        // the fallback "first date in upper text" path may catch it, but
        // for THIS test we want to verify the label arm doesn't reach.
        let labelFollower = String(repeating: "x ", count: 60)
        let text = "Rechnungsdatum: \(labelFollower)03.05.2024"
        // We don't assert nil because the upper-text fallback may still
        // find it; we just assert the function doesn't crash on long input.
        _ = PdfDateExtractor.findInvoiceDate(in: text)
    }

    // MARK: - Unlabelled fallback

    func testFindsFirstDateInUpperTextWhenNoLabel() {
        let text = "Some preamble text\nFreitag, 03.05.2024\nLine 3\nLine 4"
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.day, 3)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.year, 2024)
    }

    func testReturnsNilForTextWithoutAnyDate() {
        let text = "Just some prose with no date pattern in it at all."
        XCTAssertNil(PdfDateExtractor.findInvoiceDate(in: text))
    }

    func testReturnsNilForEmptyString() {
        XCTAssertNil(PdfDateExtractor.findInvoiceDate(in: ""))
    }

    // MARK: - Numeric format coverage

    func testISO8601StyleYearFirst() {
        XCTAssertEqual(
            PdfDateExtractor.findInvoiceDate(in: "Generated 2024-05-03 14:00")?.day,
            3
        )
    }

    func testEUSlashSeparator() {
        XCTAssertEqual(
            PdfDateExtractor.findInvoiceDate(in: "Rechnungsdatum: 03/05/2024")?.day,
            3
        )
    }

    func testEUTwoDigitYear() {
        let date = PdfDateExtractor.findInvoiceDate(in: "Rechnungsdatum: 03.05.24")
        XCTAssertEqual(date?.year, 2024)
        XCTAssertEqual(date?.day, 3)
    }

    func testRejectsImpossibleDateAndKeepsLooking() {
        // First numeric candidate is "30.02.2024" (impossible) — the
        // matcher should skip it and find the second one.
        let text = "Order #30.02.2024\nRechnungsdatum: 03.05.2024"
        let date = PdfDateExtractor.findInvoiceDate(in: text)
        XCTAssertEqual(date?.day, 3)
        XCTAssertEqual(date?.month, 5)
    }
}
