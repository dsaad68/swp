import XCTest
@testable import swp

/// The escape-sequence decoder, fed byte arrays instead of a terminal.
///
/// Worth testing exhaustively here for a reason specific to this program: a
/// sequence that is decoded wrong leaks its tail bytes back as ordinary
/// keystrokes, and an ordinary keystroke in this list can send a signal.
final class KeyDecodingTests: XCTestCase {

    private func decode(_ bytes: [UInt8]) -> Terminal.Key {
        var rest = bytes.dropFirst()
        return Terminal.decodeKey(first: bytes[0]) { _ in
            guard let next = rest.first else { return nil }
            rest = rest.dropFirst()
            return next
        }
    }

    private func esc(_ tail: String) -> [UInt8] { [0x1B] + Array(tail.utf8) }

    func testPlainKeys() {
        XCTAssertEqual(decode([0x0D]), .enter)
        XCTAssertEqual(decode([0x0A]), .enter)
        XCTAssertEqual(decode([0x09]), .tab)
        XCTAssertEqual(decode([0x7F]), .backspace)
        XCTAssertEqual(decode([0x0C]), .ctrlL)
        XCTAssertEqual(decode([0x6A]), .char("j"))
    }

    /// Ctrl-C must never decode as the letter c: a typed "c" would then be
    /// indistinguishable from an interrupt.
    func testCtrlCIsNotTheLetterC() {
        XCTAssertEqual(decode([0x03]), .ctrlC)
        XCTAssertEqual(decode([0x63]), .char("c"))
    }

    func testArrowsAndNavigation() {
        XCTAssertEqual(decode(esc("[A")), .up)
        XCTAssertEqual(decode(esc("[B")), .down)
        XCTAssertEqual(decode(esc("[C")), .right)
        XCTAssertEqual(decode(esc("[D")), .left)
        XCTAssertEqual(decode(esc("OA")), .up)      // SS3, as some terminals send
        XCTAssertEqual(decode(esc("[H")), .home)
        XCTAssertEqual(decode(esc("[F")), .end)
        XCTAssertEqual(decode(esc("[5~")), .pageUp)
        XCTAssertEqual(decode(esc("[6~")), .pageDown)
        XCTAssertEqual(decode(esc("[1~")), .home)
        XCTAssertEqual(decode(esc("[4~")), .end)
    }

    /// A modified arrow still moves, and — the point — consumes its whole
    /// parameter list, so no `;`, `2` or `A` leaks out as a keystroke.
    func testModifiedArrowsAreConsumedWhole() {
        XCTAssertEqual(decode(esc("[1;2A")), .up)
        XCTAssertEqual(decode(esc("[1;5B")), .down)
    }

    func testALoneEscapeIsEscape() {
        XCTAssertEqual(decode([0x1B]), .escape)
        XCTAssertEqual(decode(esc("x")), .escape)
    }

    func testMouseWheelBecomesAScroll() {
        XCTAssertEqual(decode(esc("[<64;10;5M")), .mouseScroll(-3))
        XCTAssertEqual(decode(esc("[<65;10;5M")), .mouseScroll(3))
    }

    /// A horizontal tilt masks to the same button bits as a vertical scroll and
    /// would otherwise read as "down" whichever way it was pushed.
    func testHorizontalWheelIsIgnored() {
        XCTAssertEqual(decode(esc("[<66;10;5M")), .other)
        XCTAssertEqual(decode(esc("[<67;10;5M")), .other)
    }

    func testLeftClickCarriesItsPosition() {
        XCTAssertEqual(decode(esc("[<0;12;7M")), .mouseClick(x: 12, y: 7))
        // A release would otherwise fire a second action for one click.
        XCTAssertEqual(decode(esc("[<0;12;7m")), .other)
        // Right and middle buttons are not bound to anything.
        XCTAssertEqual(decode(esc("[<2;12;7M")), .other)
    }
}

final class FrameSequenceTests: XCTestCase {

    /// A frame shorter than the screen clears what is below it — and only then,
    /// since on a full screen the cursor sits on the bottom-right cell and the
    /// clear would rub out the corner of the border.
    func testClearBelowOnlyOnAShortFrame() {
        let short = Terminal.frameSequence(["a", "b"], screenRows: 5)
        XCTAssertTrue(short.contains("\u{1B}[J"))
        let full = Terminal.frameSequence(["a", "b"], screenRows: 2)
        XCTAssertFalse(full.contains("\u{1B}[J"))
    }

    /// Each line is cleared *before* its text, never after: with autowrap off
    /// the cursor parks on the last column, and a trailing clear would erase it.
    func testEachLineIsClearedBeforeItIsWritten() {
        let frame = Terminal.frameSequence(["ab"], screenRows: 1)
        XCTAssertTrue(frame.contains("\u{1B}[2Kab"))
        XCTAssertFalse(frame.contains("ab\u{1B}[2K"))
    }

    /// Wrapped in a synchronised update, so a frame larger than one pty write
    /// cannot be painted in visible halves.
    func testFrameIsSynchronised() {
        let frame = Terminal.frameSequence(["a"], screenRows: 3)
        XCTAssertTrue(frame.hasPrefix("\u{1B}[?2026h"))
        XCTAssertTrue(frame.hasSuffix("\u{1B}[?2026l"))
    }
}
