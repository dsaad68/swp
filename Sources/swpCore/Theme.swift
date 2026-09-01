import Foundation

/// Colours for the picker's chrome and the printed table.
///
/// One palette drives both, so a row printed to a pipe and the same row under
/// the cursor are recognisably the same thing. Colours are 256-palette indices
/// (promoted to exact RGB when the terminal advertises truecolor), matching the
/// muted, low-saturation register termdown uses — a process list is read at a
/// glance under stress, and a bright one is harder to read, not easier.
public struct Theme: Sendable {

    public var accent: Ansi.Color        // fuzzy-match highlights, focused chrome
    public var border: Ansi.Color
    public var heading: Ansi.Color       // column headers
    public var muted: Ansi.Color         // secondary text: user, uptime, memory
    public var port: Ansi.Color          // the port column — the thing you came for
    public var exposed: Ansi.Color       // a port bound to the wildcard address
    public var pid: Ansi.Color
    public var name: Ansi.Color
    public var command: Ansi.Color
    public var selectionBg: Ansi.Color
    public var selectionFg: Ansi.Color
    public var danger: Ansi.Color        // the kill confirmation, failures
    public var success: Ansi.Color
    /// Gradient across the three letters of the wordmark, coolest first.
    ///
    /// Teal → amber, deliberately not termdown's blue → mauve: the two tools
    /// sit in the same terminal and open with the same shape of header, and the
    /// half-second of "which one did I just launch" is exactly what a wordmark
    /// exists to save. The ramp also happens to be the tool's own semantics —
    /// it ends on the colour the port column is written in.
    public var wordmark: [Ansi.Color]

    public static let dark = Theme(
        accent: 39,
        border: 240,
        heading: 245,
        muted: 244,
        port: 223,          // soft yellow
        exposed: 216,       // peach — bound to the world, not to loopback
        pid: 152,           // soft teal
        name: 183,          // mauve
        command: 250,
        selectionBg: 237,
        selectionFg: 255,
        danger: 217,        // soft red
        success: 151,       // sage
        wordmark: [80, 115, 180]     // teal → pale cyan → amber
    )

    public static let light = Theme(
        accent: 26,
        border: 250,
        heading: 240,
        muted: 243,
        port: 94,
        exposed: 130,
        pid: 30,
        name: 55,
        command: 238,
        selectionBg: 253,
        selectionFg: 232,
        danger: 124,
        success: 28,
        wordmark: [30, 66, 130]      // the same ramp, dark enough for paper
    )

    /// No colour at all — what `--no-color`, `NO_COLOR` and a redirected stdout
    /// select. The values are never emitted (every helper checks
    /// `Ansi.colorEnabled` first); the theme still exists so the drawing code
    /// has no colourless branch of its own to get wrong.
    public static let mono = Theme(
        accent: 7, border: 7, heading: 7, muted: 7, port: 7, exposed: 7,
        pid: 7, name: 7, command: 7, selectionBg: 7, selectionFg: 0,
        danger: 7, success: 7, wordmark: [7, 7, 7]
    )

    /// Look a theme up by name, falling back to `dark` — an unknown `--theme`
    /// should not stop the tool from telling you what has your port.
    public static func named(_ name: String?) -> Theme {
        switch name?.lowercased() {
        case "light": return .light
        case "mono", "none": return .mono
        default: return .dark
        }
    }

    public static let names = ["dark", "light", "mono"]
}
