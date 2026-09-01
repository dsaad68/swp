import Foundation
import swpCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Terminal {

    // MARK: - Output

    static func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    static func clearScreen() { write("\u{1B}[2J\u{1B}[H") }
    static func hideCursor() { write("\u{1B}[?25l") }
    static func showCursor() { write("\u{1B}[?25h") }
    static func moveCursor(row: Int, col: Int) { write("\u{1B}[\(row);\(col)H") }

    /// Copy `text` to the system clipboard: OSC 52 first, which works over SSH
    /// and through tmux, then `pbcopy` on macOS for terminals (Apple's own
    /// among them) that do not implement it.
    static func copyToClipboard(_ text: String) {
        write(Ansi.osc52(text))
        #if canImport(Darwin)
        let pb = "/usr/bin/pbcopy"
        guard FileManager.default.isExecutableFile(atPath: pb) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pb)
        let pipe = Pipe()
        task.standardInput = pipe
        guard (try? task.run()) != nil else { return }
        pipe.fileHandleForWriting.write(Data(text.utf8))
        try? pipe.fileHandleForWriting.close()
        task.waitUntilExit()
        #endif
    }

    // MARK: - Frames

    /// Paint a whole frame without the flash a screen clear causes.
    static func render(_ rows: [String]) {
        write(frameSequence(rows, screenRows: size().rows))
    }

    /// Build the byte stream `render` writes. Pure, so the cursor and clear
    /// placement that keeps a frame sealed can be tested without a terminal.
    ///
    /// Two edges matter, both because autowrap is off (`\e[?7l`) and so the
    /// cursor parks *on* the last column after a full-width row instead of
    /// stepping past it:
    ///   - the per-line clear (`\e[2K`) goes at the *start* of a line, never
    ///     after its text, where it would erase that last column;
    ///   - the clear-below (`\e[J`) runs only when the frame is shorter than the
    ///     screen, after stepping onto the first blank line — on a full screen
    ///     the cursor sits on the bottom-right cell and `\e[J` would rub out the
    ///     corner of the border.
    /// The whole thing is wrapped in a synchronised update (DEC mode 2026) so a
    /// frame larger than a pty write cannot be painted half-drawn; terminals
    /// that do not implement it ignore both sequences.
    static func frameSequence(_ rows: [String], screenRows: Int) -> String {
        var buf = "\u{1B}[?2026h\u{1B}[H"
        for (i, row) in rows.enumerated() {
            buf += "\u{1B}[2K" + row
            if i < rows.count - 1 { buf += "\r\n" }
        }
        if rows.count < screenRows { buf += "\r\n\u{1B}[J" }
        return buf + "\u{1B}[?2026l"
    }
}
