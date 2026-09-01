import Foundation
import swpCore

extension ProcessMenu {

    /// How much of the frame the header takes, and which header it is.
    ///
    /// The full header — wordmark, subtitle, a boxed filter field — costs
    /// eleven rows. That is worth it on a normal terminal and absurd on a short
    /// one, where it would leave four rows of list, so anything under 22 rows
    /// gets the compact header instead. The click handler reads the same value,
    /// which is what keeps the row under the pointer and the row under the
    /// cursor the same row.
    struct Chrome: Equatable {
        var full: Bool
        /// Top border, spacer, wordmark (3), subtitle, spacer, filter box (3),
        /// column header — or, compact: top border, title, filter line, column
        /// header.
        var headerLines: Int { full ? 11 : 4 }
        /// Hint line and bottom border.
        var footerLines: Int { 2 }

        init(size: Terminal.Size, width: Int) {
            // The wordmark needs both the rows to sit in and the width to sit
            // beside a subtitle without either being truncated.
            full = size.rows >= 22 && width >= 52
        }
    }

    /// Thin-line wordmark glyphs (3 rows each) for s·w·p, drawn in the same
    /// stroke as termdown's — same family of tool, same hand.
    static let wordmarkGlyphs: [[String]] = [
        ["╭─╴", "╰─╮", "╶─╯"],   // s
        ["╷ ╷", "│ │", "╰┴╯"],   // w
        ["╭─╮", "├─╯", "╵  "],   // p
    ]

    /// The three coloured rows of the wordmark, letters spaced by a column.
    func wordmarkRows() -> [String] {
        var rows = ["", "", ""]
        for (index, glyph) in Self.wordmarkGlyphs.enumerated() {
            for row in 0..<3 {
                rows[row] += Ansi.color(glyph[row], theme.wordmark[index])
                if index < Self.wordmarkGlyphs.count - 1 { rows[row] += " " }
            }
        }
        return rows
    }

    /// "swp" on one line with the same gradient, for terminals too small for
    /// the art. Bold as well as coloured, so it still reads as a title where a
    /// font ships no bold face.
    func wordmarkInline() -> String {
        var out = ""
        for (index, character) in "swp".enumerated() {
            out += Ansi.wrap(String(character), [1] + Ansi.fg(theme.wordmark[index]))
        }
        return out
    }

    /// The subtitle under the wordmark: what is being listed on the left, how
    /// it is ordered and the version on the right.
    ///
    /// The left side is the answer to "what am I looking at" and the right to
    /// "why is it in this order", so when the width runs out the right side is
    /// what goes — the same priority termdown's header uses.
    func subtitleLine(inner: Int) -> String {
        let noun = showsPortless ? "processes" : "listening"
        let count = visibleRows.count == totalCount
            ? "\(totalCount) \(noun)"
            : "\(visibleRows.count) of \(totalCount) \(noun)"
        let left = Ansi.color(count, theme.heading)
            + Ansi.color("  ·  ", theme.border)
            + Ansi.color(restrictedToMe ? "mine" : "all users", theme.muted)

        let right = Ansi.color("by \(sort.label)", theme.muted)
            + Ansi.color("  ·  ", theme.border)
            + Ansi.color("v\(appVersion)", theme.muted)

        let used = Ansi.displayWidth(left) + Ansi.displayWidth(right)
        guard used + 2 <= inner else { return Format.truncate(left, to: inner) }
        return left + String(repeating: " ", count: inner - used) + right
    }

    /// The three rows of the boxed filter field.
    ///
    /// A box rather than a bare line because it is the one place in the frame
    /// that takes typing, and a field that looks like a field is the cheapest
    /// way to say so — the focused state then only has to change its colour.
    func filterBoxRows(inner: Int) -> [String] {
        let width = max(10, inner - 2)
        let colour = isSearching ? theme.accent : theme.border
        let rule = String(repeating: "─", count: max(0, width - 2))
        let top = Ansi.color("╭\(rule)╮", colour)
        let bottom = Ansi.color("╰\(rule)╯", colour)

        let prompt = Ansi.color("❯", isSearching ? theme.accent : theme.muted)
        let body: String
        if filterText.isEmpty, !isSearching {
            body = Ansi.color("press / to filter — by name, port, pid, anything", theme.muted)
        } else {
            body = Ansi.color(Format.truncate(filterText, to: max(1, width - 6)), theme.accent)
                + (isSearching ? Ansi.color("▏", theme.accent) : "")
        }
        let content = "\(prompt) \(body)"
        let padding = max(0, width - 4 - Ansi.displayWidth(content))
        let middle = Ansi.color("│", colour) + " " + content + String(repeating: " ", count: padding)
            + " " + Ansi.color("│", colour)

        return [top, middle, bottom].map { " " + $0 }
    }
}
