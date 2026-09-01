import XCTest
@testable import swpCore

final class AnsiTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Ansi.colorEnabled = true
        Ansi.truecolor = false
    }

    /// The measurement that keeps every column aligned: escapes are zero-width.
    func testDisplayWidthIgnoresEscapes() {
        let styled = Ansi.color("3000", 39)
        XCTAssertGreaterThan(styled.count, 4)
        XCTAssertEqual(Ansi.displayWidth(styled), 4)
    }

    func testDisplayWidthCountsWideCharacters() {
        XCTAssertEqual(Ansi.displayWidth("abc"), 3)
        XCTAssertEqual(Ansi.displayWidth("日本語"), 6)
        XCTAssertEqual(Ansi.displayWidth("🚀"), 2)
        // A ZWJ sequence is drawn as one glyph, not as the sum of its parts.
        XCTAssertEqual(Ansi.displayWidth("👩‍💻"), 2)
    }

    func testDisplayWidthSkipsOSCSequences() {
        XCTAssertEqual(Ansi.displayWidth(Ansi.osc52("hello") + "ok"), 2)
    }

    func testColorCanBeTurnedOffEntirely() {
        Ansi.colorEnabled = false
        XCTAssertEqual(Ansi.color("x", 39), "x")
        XCTAssertEqual(Ansi.code([1, 2]), "")
        Ansi.colorEnabled = true
    }

    func testTruecolorEmitsExactRGB() {
        Ansi.truecolor = true
        XCTAssertEqual(Ansi.code(Ansi.fg(.rgb(1, 2, 3))), "\u{1B}[38;2;1;2;3m")
        Ansi.truecolor = false
        // Without truecolor an RGB value falls back to the nearest palette slot.
        let codes = Ansi.fg(.rgb(0, 0, 0))
        XCTAssertEqual(codes.prefix(2).map { $0 }, [38, 5])
    }
}
