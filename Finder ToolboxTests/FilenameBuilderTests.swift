import XCTest
@testable import Finder_Toolbox

/// Covers the filesystem length clamp (`fitting`) and placeholder-date
/// rendering. `FilenameBuilder.canonical` itself reads the style from
/// UserDefaults, so these tests target the defaults-independent pieces:
/// `fitting(stem:suffix:ext:)` and `DateFormatStyle.format` on fixed cases.
final class FilenameBuilderTests: XCTestCase {

    // MARK: - Length clamping

    func testShortNamePassesThroughUnchanged() {
        XCTAssertEqual(
            FilenameBuilder.fitting(stem: "2026-08-14 Invoice", ext: "pdf"),
            "2026-08-14 Invoice.pdf"
        )
    }

    func testLongNameClampsTo255Bytes() {
        let stem = "2026-08-14 " + String(repeating: "a", count: 300)
        let result = FilenameBuilder.fitting(stem: stem, ext: "pdf")
        XCTAssertEqual(result.utf8.count, 255)
        XCTAssertTrue(result.hasPrefix("2026-08-14 "))
        XCTAssertTrue(result.hasSuffix(".pdf"))
    }

    func testConflictSuffixSurvivesClamping() {
        let stem = "2026-08-14 " + String(repeating: "a", count: 300)
        let result = FilenameBuilder.fitting(stem: stem, suffix: " 2", ext: "pdf")
        XCTAssertLessThanOrEqual(result.utf8.count, 255)
        XCTAssertTrue(result.hasSuffix(" 2.pdf"))
    }

    func testTruncationRespectsCharacterBoundaries() {
        // 4-byte scalars: the cut must never split one mid-character.
        let stem = "2026-08-14 " + String(repeating: "🙂", count: 100)
        let result = FilenameBuilder.fitting(stem: stem, ext: "pdf")
        XCTAssertLessThanOrEqual(result.utf8.count, 255)
        XCTAssertTrue(result.hasSuffix(".pdf"))
        // A split scalar would produce a replacement character on re-decode.
        XCTAssertFalse(result.contains("\u{FFFD}"))
    }

    func testTruncationTrimsTrailingSeparatorNoise() {
        let stem = "2026-08-14 " + String(repeating: "a", count: 239) + " - trailing"
        let result = FilenameBuilder.fitting(stem: stem, ext: "pdf")
        XCTAssertFalse(result.hasSuffix(" .pdf"))
        XCTAssertFalse(result.hasSuffix("-.pdf"))
    }

    // MARK: - Placeholder date rendering

    func testPlaceholderRendersInFixedStyles() {
        var year = DateComponents()
        year.year = 2026; year.month = 0; year.day = 0
        XCTAssertEqual(DateFormatStyle.iso.format(year), "2026-00-00")
        XCTAssertEqual(DateFormatStyle.compact.format(year), "20260000")
        XCTAssertEqual(DateFormatStyle.underscore.format(year), "2026_00_00")
        XCTAssertEqual(DateFormatStyle.dottedDE.format(year), "00.00.2026")
        XCTAssertEqual(DateFormatStyle.dashedDE.format(year), "00-00-2026")

        var month = DateComponents()
        month.year = 2025; month.month = 1; month.day = 0
        XCTAssertEqual(DateFormatStyle.iso.format(month), "2025-01-00")
        XCTAssertEqual(DateFormatStyle.compact.format(month), "20250100")
    }

    func testRealDateStillUsesCalendarPath() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 8; comps.day = 14
        XCTAssertEqual(DateFormatStyle.iso.format(comps), "2026-08-14")
    }
}
