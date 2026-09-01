import Foundation

/// ANSI SGR helpers and display-width measurement.
///
/// A trimmed cousin of the same file in termdown: `swp` draws a table, not a
/// document, so it needs colour, width and nothing else. Everything routes
/// through `colorEnabled` so `--no-color` (and a redirected stdout) produce
/// byte-for-byte plain text rather than text with the escapes stripped later.
public enum Ansi {

    static let esc = "\u{1B}"
    /// The all-off sequence, ending every styled run.
    public static let reset = "\u{1B}[0m"

    /// Turned off by `--no-color`, by `NO_COLOR`, and whenever stdout is not a
    /// terminal. Checked at every call site rather than at the top, so a single
    /// assignment in `main` covers the whole program.
    public static var colorEnabled = true

    /// Whether the terminal advertises 24-bit colour (`$COLORTERM`). When it
    /// does, palette entries are emitted as their exact RGB so the chrome
    /// matches across terminals whose 256-palette differs.
    public static var truecolor = false

    // MARK: - Colour

    /// A colour: a 256-palette index, or an absolute 24-bit triple. Integer
    /// literals build `.x256`, so a palette table reads as plain numbers.
    public enum Color: Hashable, ExpressibleByIntegerLiteral, Sendable {
        case x256(Int)
        case rgb(UInt8, UInt8, UInt8)
        public init(integerLiteral value: Int) { self = .x256(value) }

        public static func hex(_ v: Int) -> Color {
            .rgb(UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
        }
    }

    public static func code(_ codes: [Int]) -> String {
        colorEnabled && !codes.isEmpty ? "\(esc)[\(codes.map(String.init).joined(separator: ";"))m" : ""
    }

    public static func wrap(_ s: String, _ codes: [Int]) -> String {
        colorEnabled && !codes.isEmpty ? code(codes) + s + reset : s
    }

    public static func fg(_ c: Color) -> [Int] { sgr(c, base: 38) }
    public static func bg(_ c: Color) -> [Int] { sgr(c, base: 48) }

    private static func sgr(_ c: Color, base: Int) -> [Int] {
        switch c {
        case .x256(let n):
            if truecolor { let (r, g, b) = palette256RGB(n); return [base, 2, r, g, b] }
            return [base, 5, n]
        case .rgb(let r, let g, let b):
            if truecolor { return [base, 2, Int(r), Int(g), Int(b)] }
            return [base, 5, nearest256(Int(r), Int(g), Int(b))]
        }
    }

    public static func color(_ s: String, _ c: Color) -> String { wrap(s, fg(c)) }
    public static func fgBg(_ s: String, fg f: Color, bg b: Color) -> String { wrap(s, fg(f) + bg(b)) }
    public static func bold(_ s: String) -> String { wrap(s, [1]) }
    public static func dim(_ s: String) -> String { wrap(s, [2]) }
    public static func italic(_ s: String) -> String { wrap(s, [3]) }
    public static func underline(_ s: String) -> String { wrap(s, [4]) }
    public static func reverse(_ s: String) -> String { wrap(s, [7]) }

    /// A readable text colour to put *on* `bg`, by perceived luminance. The
    /// themes pick their own accents; this is for the one place a background is
    /// chosen dynamically (the selection band under a user-set theme).
    public static func contrastingText(on bg: Color) -> Color {
        let (r, g, b): (Int, Int, Int)
        switch bg {
        case .rgb(let rr, let gg, let bb): (r, g, b) = (Int(rr), Int(gg), Int(bb))
        case .x256(let n): (r, g, b) = palette256RGB(n)
        }
        return (r * 299 + g * 587 + b * 114) / 1000 > 140 ? .rgb(28, 28, 34) : .rgb(238, 238, 244)
    }

    /// OSC 52 clipboard write, so `y` copies a pid even over SSH, where a
    /// host-side `pbcopy` would land on the wrong machine's clipboard.
    public static func osc52(_ text: String) -> String {
        "\(esc)]52;c;\(Data(text.utf8).base64EncodedString())\(esc)\\"
    }

    // MARK: - Palette conversion

    /// RGB for a 256-palette index: the 16 system colours (approximated with
    /// the widely-used xterm values), the 6×6×6 cube, then the 24-step ramp.
    static func palette256RGB(_ n: Int) -> (Int, Int, Int) {
        if n < 16 { return systemPalette[max(0, n)] }
        if n < 232 {
            let i = n - 16
            let steps = [0, 95, 135, 175, 215, 255]
            return (steps[(i / 36) % 6], steps[(i / 6) % 6], steps[i % 6])
        }
        let level = 8 + (min(n, 255) - 232) * 10
        return (level, level, level)
    }

    private static let systemPalette: [(Int, Int, Int)] = [
        (0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0),
        (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
        (128, 128, 128), (255, 0, 0), (0, 255, 0), (255, 255, 0),
        (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255),
    ]

    /// Nearest 256-palette index for an RGB triple, searching the cube and the
    /// grey ramp separately — a near-grey is better served by the ramp's 24
    /// steps than by the cube's 6.
    static func nearest256(_ r: Int, _ g: Int, _ b: Int) -> Int {
        let steps = [0, 95, 135, 175, 215, 255]
        func closest(_ v: Int) -> Int {
            var best = 0
            for (i, s) in steps.enumerated() where abs(s - v) < abs(steps[best] - v) { best = i }
            return best
        }
        let ci = 16 + 36 * closest(r) + 6 * closest(g) + closest(b)
        let (cr, cg, cb) = palette256RGB(ci)
        let cubeErr = (cr - r) * (cr - r) + (cg - g) * (cg - g) + (cb - b) * (cb - b)

        let grey = max(0, min(23, ((r + g + b) / 3 - 8) / 10))
        let gi = 232 + grey
        let (gr, gg, gb) = palette256RGB(gi)
        let greyErr = (gr - r) * (gr - r) + (gg - g) * (gg - g) + (gb - b) * (gb - b)

        return greyErr < cubeErr ? gi : ci
    }
}
