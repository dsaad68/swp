import XCTest
@testable import swpCore

final class FormatTests: XCTestCase {

    func testBytesUsesBinaryUnits() {
        XCTAssertEqual(Format.bytes(0), "0B")
        XCTAssertEqual(Format.bytes(512), "512B")
        XCTAssertEqual(Format.bytes(1024), "1.0K")
        XCTAssertEqual(Format.bytes(1024 * 1024), "1.0M")
        XCTAssertEqual(Format.bytes(12 * 1024 * 1024), "12M")
        XCTAssertEqual(Format.bytes(1_500_000_000), "1.4G")
    }

    func testBytesOfNothingIsADash() {
        XCTAssertEqual(Format.bytes(nil), "-")
    }

    func testElapsedPicksOneUnit() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.elapsed(since: now.addingTimeInterval(-3), now: now), "3s")
        XCTAssertEqual(Format.elapsed(since: now.addingTimeInterval(-90), now: now), "1m")
        XCTAssertEqual(Format.elapsed(since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(Format.elapsed(since: now.addingTimeInterval(-200_000), now: now), "2d")
        XCTAssertEqual(Format.elapsed(since: nil, now: now), "-")
    }

    /// A start time a hair in the future — a clock that stepped, or a process
    /// started in the same second — must not print a negative age.
    func testElapsedNeverGoesNegative() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Format.elapsed(since: now.addingTimeInterval(5), now: now), "0s")
    }

    func testTruncateKeepsTheHeadAndMarksTheCut() {
        XCTAssertEqual(Format.truncate("node server.js", to: 20), "node server.js")
        XCTAssertEqual(Format.truncate("node server.js", to: 8), "node se…")
        XCTAssertEqual(Ansi.displayWidth(Format.truncate("node server.js", to: 8)), 8)
        XCTAssertEqual(Format.truncate("abc", to: 0), "")
    }

    /// A cut that lands mid-emoji must not leave a row one column wide.
    func testTruncateMeasuresWideCharacters() {
        let text = "🚀🚀🚀"
        XCTAssertEqual(Ansi.displayWidth(Format.truncate(text, to: 5)), 5)
    }

    func testPaddingIsMeasuredInDisplayColumns() {
        XCTAssertEqual(Format.pad("ab", to: 5), "ab   ")
        XCTAssertEqual(Format.padLeft("42", to: 5), "   42")
        // Already at or over the width: padding never truncates.
        XCTAssertEqual(Format.pad("abcdef", to: 3), "abcdef")
    }
}

extension FormatTests {

    func testPercentKeepsOneDecimalOnlyWhereItMatters() {
        XCTAssertEqual(Format.percent(0.42), "0.4%")
        XCTAssertEqual(Format.percent(4.25), "4.2%")
        XCTAssertEqual(Format.percent(42.4), "42%")
        // Over one core is a real reading, not something to clamp.
        XCTAssertEqual(Format.percent(137.2), "137%")
    }

    /// An unknown is not a zero: the kernel refusing to say is a different
    /// fact from the process being idle, and the column must not merge them.
    func testPercentDistinguishesUnknownFromIdle() {
        XCTAssertEqual(Format.percent(nil), "-")
        XCTAssertEqual(Format.percent(0), "0%")
        XCTAssertEqual(Format.percent(0.001), "0%")
    }
}
