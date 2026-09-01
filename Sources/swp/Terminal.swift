import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Low-level terminal control: raw mode, the alternate screen, mouse tracking,
/// cleanup hooks and the window size. Key decoding, drawing and overlays live
/// in the `Terminal+*` extensions.
///
/// Every state change here outlives the process if it is not undone — a program
/// that exits from raw mode without restoring it leaves the user typing into a
/// shell that no longer echoes. So each toggle is idempotent, and
/// `installCleanup()` puts the restore behind `atexit` and the fatal signals
/// rather than trusting any particular code path to be taken.
enum Terminal {

    // MARK: - Raw mode

    private static var savedTermios: termios?
    private static var altScreenActive = false

    /// Set by the `SIGWINCH` handler; the picker polls it to redraw on resize.
    static var didResize = false

    /// Enter raw (cbreak) mode: no echo, no line buffering. `ISIG` stays on so
    /// Ctrl-C still interrupts — a tool whose whole job is killing things should
    /// be the easiest thing on the screen to kill.
    static func enableRawMode() {
        var raw = termios()
        guard tcgetattr(STDIN_FILENO, &raw) == 0 else { return }
        if savedTermios == nil { savedTermios = raw }

        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        raw.c_iflag &= ~tcflag_t(ICRNL | IXON)

        // VMIN = 1, VTIME = 0 → a read returns as soon as one byte is there.
        withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
            ptr.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { cc in
                cc[Int(VMIN)] = 1
                cc[Int(VTIME)] = 0
            }
        }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    }

    /// Restore the mode captured before `enableRawMode()`.
    static func disableRawMode() {
        guard var saved = savedTermios else { return }
        _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        disableMouseTracking()
    }

    // MARK: - Mouse

    private static var mouseActive = false

    /// Report wheel and click events (SGR mode). Motion is deliberately not
    /// requested: `?1002h` would take click-drag away from the terminal's own
    /// text selection, and there is nothing here worth dragging — but there is
    /// plenty worth copying out of the list with the mouse.
    static func enableMouseTracking() {
        guard !mouseActive else { return }
        mouseActive = true
        write("\u{1B}[?1000h\u{1B}[?1006h")
    }

    static func disableMouseTracking() {
        guard mouseActive else { return }
        mouseActive = false
        write("\u{1B}[?1006l\u{1B}[?1000l")
    }

    // MARK: - Alternate screen

    /// Switch to the alternate screen buffer so the user's scrollback survives,
    /// and turn autowrap off (`?7l`).
    ///
    /// The picker positions every cell and draws exactly `rows` lines a frame.
    /// If one row's width is ever a column over — a name with an emoji in it,
    /// measured single-width by the tables and drawn double by the terminal —
    /// autowrap would push it onto a second physical line and every later
    /// `\e[H` redraw would be one row out. With autowrap off the overflow is
    /// clipped at the margin instead and the frame stays aligned.
    static func enterAltScreen() {
        guard !altScreenActive else { return }
        write("\u{1B}[?1049h\u{1B}[?7l")
        altScreenActive = true
    }

    static func exitAltScreen() {
        guard altScreenActive else { return }
        write("\u{1B}[?7h\u{1B}[?1049l")
        altScreenActive = false
    }

    /// Install the handlers that put the terminal back however the program ends.
    static func installCleanup() {
        atexit {
            Terminal.showCursor()
            Terminal.exitAltScreen()
            Terminal.disableRawMode()
        }
        for sig in [SIGINT, SIGTERM] {
            signal(sig) { _ in
                // Only the state that outlives the process is restored here;
                // `_exit` takes everything else with it, and the handler must
                // stay async-signal-safe.
                Terminal.showCursor()
                Terminal.exitAltScreen()
                Terminal.disableRawMode()
                _exit(130)
            }
        }
        signal(SIGWINCH) { _ in Terminal.didResize = true }
    }

    /// Run `body` inside a fully set-up terminal UI, tearing it down afterwards
    /// however it ends. The one place raw mode and the alternate screen are
    /// entered, so they cannot get out of step.
    static func withUI<T>(mouse: Bool, _ body: () -> T) -> T {
        installCleanup()
        enableRawMode()
        enterAltScreen()
        if mouse { enableMouseTracking() }
        defer {
            disableMouseTracking()
            exitAltScreen()
            disableRawMode()
            showCursor()
        }
        return body()
    }

    // MARK: - Size

    struct Size: Equatable {
        var rows: Int
        var cols: Int
    }

    /// The window size in cells, falling back to 80×24 — the size a terminal
    /// that will not answer is required to behave as.
    static func size() -> Size {
        var ws = winsize()
        let ok = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0
        let rows = ok && ws.ws_row > 0 ? Int(ws.ws_row) : 24
        let cols = ok && ws.ws_col > 0 ? Int(ws.ws_col) : 80
        return Size(rows: rows, cols: cols)
    }

    /// Whether both ends of the pipeline are a terminal.
    ///
    /// Both, not either: a keyboard UI needs somewhere to draw *and* somewhere
    /// to read keys from. With stdout redirected it would paint a frame into a
    /// file; with stdin redirected it would block forever on a key that cannot
    /// arrive. `swp | grep` used to be exactly that hang in tools that check
    /// only one.
    static var isInteractive: Bool {
        isatty(STDOUT_FILENO) != 0 && isatty(STDIN_FILENO) != 0
    }
}
