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

    func testRemainderStripsSeparators() {
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03_Invoice")?.remainder, "Invoice")
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03-Invoice")?.remainder, "Invoice")
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03 Invoice")?.remainder, "Invoice")
    }

    func testEmptyRemainderForBareDateStem() {
        XCTAssertEqual(DateDetector.detect(in: "2024-05-03")?.remainder, "")
    }
}
