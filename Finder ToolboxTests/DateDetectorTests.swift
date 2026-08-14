import XCTest
@testable import Finder_Toolbox

/// Covers the leading-date-prefix patterns the v1 rename pipeline supports
/// (the patterns documented in ROADMAP §"Date detector"). The pure-function
/// surface — `detect(in:)` — makes this the easiest of the three extractors
/// to test exhaustively.
final class DateDetectorTests: XCTestCase {

    func testDetectsYYYYDashMMDashDD() {
        let result = DateDetector.detect(in: "2024-05-03 Invoice")
        XCTAssertEqual(result?.date.year, 2024)
        XCTAssertEqual(result?.date.month, 5)
        XCTAssertEqual(result?.date.day, 3)
        XCTAssertEqual(result?.remainder, "Invoice")
    }

    func testDetectsYYYYMMDDPacked() {
        let result = DateDetector.detect(in: "20240503 Invoice")
        XCTAssertEqual(result?.date.year, 2024)
        XCTAssertEqual(result?.date.month, 5)
        XCTAssertEqual(result?.date.day, 3)
        XCTAssertEqual(result?.remainder, "Invoice")
    }

    func testDetectsDDDotMMDotYYYY() {
        let result = DateDetector.detect(in: "03.05.2024_Invoice")
        XCTAssertEqual(result?.date.year, 2024)
        XCTAssertEqual(result?.date.month, 5)
        XCTAssertEqual(result?.date.day, 3)
        XCTAssertEqual(result?.remainder, "Invoice")
    }

    func testDetectsDDDotMMDotYY() {
        let result = DateDetector.detect(in: "03.05.24 Invoice")
        XCTAssertEqual(result?.date.year, 2024)
        XCTAssertEqual(result?.date.month, 5)
        XCTAssertEqual(result?.date.day, 3)
    }

    func testTwoDigitYearBefore70RollsTo2000s() {
        // Anchor: "69" → 2069, "70" → 1970. Documented in DateDetector.fullYear.
        // Packed pattern is YYMMDD (not DDMMYY), so leading digits are the year.
        XCTAssertEqual(DateDetector.detect(in: "690503 Foo")?.date.year, 2069)
        XCTAssertEqual(DateDetector.detect(in: "700503 Foo")?.date.year, 1970)
    }

    func testDoesNotMatchMidFilenameDate() {
        // The renamer deliberately ignores embedded dates so a name like
        // "Photo from 2024-05-03.jpg" gets today's date prefixed.
        XCTAssertNil(DateDetector.detect(in: "Photo from 2024-05-03"))
    }

    func testRejectsImpossibleDates() {
        XCTAssertNil(DateDetector.detect(in: "2024-13-01 Invoice"))   // month 13
        XCTAssertNil(DateDetector.detect(in: "2024-02-30 Invoice"))   // Feb 30
        XCTAssertNil(DateDetector.detect(in: "2024-00-15 Invoice"))   // month 0
    }

    func testDetectsWholeYearPlaceholder() {
        // "00" zeroes out precision the user doesn't have: 260000 = sometime in 2026.
        let result = DateDetector.detect(in: "260000 Taxes")
        XCTAssertEqual(result?.date.year, 2026)
        XCTAssertEqual(result?.date.month, 0)
        XCTAssertEqual(result?.date.day, 0)
        XCTAssertEqual(result?.remainder, "Taxes")
    }

    func testDetectsWholeMonthPlaceholder() {
        let result = DateDetector.detect(in: "250100 Statements")
        XCTAssertEqual(result?.date.year, 2025)
        XCTAssertEqual(result?.date.month, 1)
        XCTAssertEqual(result?.date.day, 0)
        XCTAssertEqual(result?.remainder, "Statements")
    }

    func testDetectsIsoPlaceholders() {
        let year = DateDetector.detect(in: "2026-00-00 Taxes")
        XCTAssertEqual(year?.date.year, 2026)
        XCTAssertEqual(year?.date.month, 0)
        XCTAssertEqual(year?.date.day, 0)

        let month = DateDetector.detect(in: "2025-01-00 Statements")
        XCTAssertEqual(month?.date.year, 2025)
        XCTAssertEqual(month?.date.month, 1)
        XCTAssertEqual(month?.date.day, 0)
    }

    func testDetectsBareYearPrefix() {
        for stem in ["2026 Taxes", "2026_Taxes"] {
            let result = DateDetector.detect(in: stem)
            XCTAssertEqual(result?.date.year, 2026, "failed for \(stem)")
            XCTAssertEqual(result?.date.month, 0, "failed for \(stem)")
            XCTAssertEqual(result?.date.day, 0, "failed for \(stem)")
            XCTAssertEqual(result?.remainder, "Taxes", "failed for \(stem)")
        }
        // A folder named just by year.
        XCTAssertEqual(DateDetector.detect(in: "2026")?.remainder, "")
        // Dashed year prefixes are deliberately NOT treated as bare years.
        XCTAssertNil(DateDetector.detect(in: "2026-Taxes"))
        // Out-of-range numbers aren't years.
        XCTAssertNil(DateDetector.detect(in: "0123 Scan"))
        XCTAssertNil(DateDetector.detect(in: "2199 Scan"))
    }

    func testDetectsTwoDigitYearPrefix() {
        for stem in ["26 Taxes", "26_Taxes"] {
            let result = DateDetector.detect(in: stem)
            XCTAssertEqual(result?.date.year, 2026, "failed for \(stem)")
            XCTAssertEqual(result?.date.month, 0, "failed for \(stem)")
            XCTAssertEqual(result?.date.day, 0, "failed for \(stem)")
            XCTAssertEqual(result?.remainder, "Taxes", "failed for \(stem)")
        }
        // Documented trade-off of the YY form: list/track numbering parses
        // as a year. Acceptable per issue discussion; full dates and
        // 4-digit years always win first.
        XCTAssertEqual(DateDetector.detect(in: "01 Intro")?.date.year, 2001)
    }

    func testDetectsYearMonthPrefix() {
        for stem in ["2026-07 Statements", "2026_07 Statements"] {
            let result = DateDetector.detect(in: stem)
            XCTAssertEqual(result?.date.year, 2026, "failed for \(stem)")
            XCTAssertEqual(result?.date.month, 7, "failed for \(stem)")
            XCTAssertEqual(result?.date.day, 0, "failed for \(stem)")
            XCTAssertEqual(result?.remainder, "Statements", "failed for \(stem)")
        }
        // Month 13+ isn't a month-precision date; and the bare-year pattern
        // must not salvage it (dashed years are excluded there).
        XCTAssertNil(DateDetector.detect(in: "2026-13 Q"))
    }

    func testFullDatesStillWinOverPlaceholderForms() {
        // "2024-05-03" must parse as a full date, not year "2024" + remainder.
        let result = DateDetector.detect(in: "2024-05-03 Invoice")
        XCTAssertEqual(result?.date.day, 3)
        // Packed YYMMDD keeps winning over bare-YY ("260000" has no separator).
        XCTAssertEqual(DateDetector.detect(in: "260514 Foo")?.date.day, 14)
    }

    func testRejectsZeroMonthWithRealDay() {
        // "Unknown month, known day" is meaningless.
        XCTAssertNil(DateDetector.detect(in: "260015 Foo"))
    }

    func testRemainderStripsSeparators() {
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03_Invoice")?.remainder, "Invoice")
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03-Invoice")?.remainder, "Invoice")
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03 Invoice")?.remainder, "Invoice")
    }

    func testEmptyRemainderForBareDateStem() {
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03")?.remainder, "")
    }
}
