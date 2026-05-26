import XCTest
@testable import Finder_Toolbox

/// `EmlDateExtractor` is normally fed an `.eml` URL. To keep these tests
/// hermetic we write tiny fixture files to a temp directory and let the
/// extractor open them like any other email.
final class EmlDateExtractorTests: XCTestCase {

    private func writeEml(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FinderToolboxTests-\(UUID().uuidString).eml")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    override func tearDown() {
        // Sweep up any temp files our tests created.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasPrefix("FinderToolboxTests-") {
                try? fm.removeItem(at: url)
            }
        }
        super.tearDown()
    }

    func testParsesStandardRFC2822DateWithDayPrefix() throws {
        let url = try writeEml("""
            From: alice@example.com
            To: bob@example.com
            Subject: Hello
            Date: Wed, 03 May 2024 10:30:45 +0200

            Body
            """)
        let date = EmlDateExtractor.extractDate(from: url)
        XCTAssertEqual(date?.year, 2024)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 3)
    }

    func testParsesRFC2822WithoutDayPrefix() throws {
        let url = try writeEml("""
            From: a@b
            Date: 03 May 2024 10:30:45 +0200

            Body
            """)
        let date = EmlDateExtractor.extractDate(from: url)
        XCTAssertEqual(date?.year, 2024)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.day, 3)
    }

    func testStripsTrailingTimezoneCommentBeforeParsing() throws {
        // RFC 2822 §3.3 allows a parenthesised TZ comment after the offset.
        let url = try writeEml("""
            From: a@b
            Date: Wed, 03 May 2024 10:30:45 +0200 (CEST)

            Body
            """)
        let date = EmlDateExtractor.extractDate(from: url)
        XCTAssertEqual(date?.day, 3)
        XCTAssertEqual(date?.month, 5)
        XCTAssertEqual(date?.year, 2024)
    }

    func testDeliveryDateWinsOverDate() throws {
        // The extractor prefers Delivery-date over Date — important when
        // the email was sent late at night UTC but delivered the next day
        // in the local timezone.
        let url = try writeEml("""
            From: a@b
            Date: Wed, 02 May 2024 23:30:00 +0000
            Delivery-date: Thu, 03 May 2024 01:30:00 +0200

            Body
            """)
        let date = EmlDateExtractor.extractDate(from: url)
        XCTAssertEqual(date?.day, 3)
    }

    func testTimezoneOffsetIsRespectedForDayBoundary() throws {
        // 23:30 UTC + 02:00 offset == 01:30 next morning local — extractor
        // should report the local day, not UTC.
        let url = try writeEml("""
            From: a@b
            Date: Wed, 02 May 2024 23:30:00 +0200

            Body
            """)
        let date = EmlDateExtractor.extractDate(from: url)
        XCTAssertEqual(date?.day, 2)
        XCTAssertEqual(date?.month, 5)
    }

    func testReturnsNilWhenNoDateHeader() throws {
        let url = try writeEml("""
            From: a@b
            Subject: no date

            Body
            """)
        XCTAssertNil(EmlDateExtractor.extractDate(from: url))
    }

    func testReturnsNilWhenDateMalformed() throws {
        let url = try writeEml("""
            From: a@b
            Date: yesterday at lunch

            Body
            """)
        XCTAssertNil(EmlDateExtractor.extractDate(from: url))
    }

    func testHandlesFoldedHeaderContinuationLines() throws {
        // RFC 2822 §2.2.3 — long header lines can fold onto continuation
        // lines that start with whitespace. `unfoldHeaders` should glue
        // them back together before parsing.
        let url = try writeEml("From: a@b\r\nDate: Wed, 03 May 2024\r\n 10:30:45 +0200\r\n\r\nBody\r\n")
        let date = EmlDateExtractor.extractDate(from: url)
        XCTAssertEqual(date?.day, 3)
    }
}
