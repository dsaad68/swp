import Foundation
import swpCore

extension Terminal {

    /// Draw a box centred on the screen, over whatever is already there.
    ///
    /// Painted in place rather than as part of a frame: the caller's frame is
    /// still on screen and still correct, and redrawing the whole thing with a
    /// dialog composited into it would mean every drawing function knowing
    /// about dialogs. The caller redraws once the overlay is dismissed.
    static func overlay(title: String, lines: [String], theme: Theme,
                        accent: Ansi.Color? = nil) {
        let size = size()
        let colour = accent ?? theme.accent
        let content = max(
            Ansi.displayWidth(title) + 4,
            lines.map { Ansi.displayWidth($0) }.max() ?? 0
        )
        let inner = min(content, max(20, size.cols - 8))
        let boxWidth = inner + 4
        let boxHeight = lines.count + 2
        let left = max(1, (size.cols - boxWidth) / 2 + 1)
        let top = max(1, (size.rows - boxHeight) / 2 + 1)

        // A title inlaid in the top border, the way a fieldset is drawn: it
        // costs no line of its own, which matters for a dialog that has to fit
        // on a short terminal.
        let heading = " \(title) "
        let dashes = max(0, inner + 2 - Ansi.displayWidth(heading))
        let leading = min(2, dashes)
        var out = ""
        out += moveTo(top, left) + Ansi.color("╭" + String(repeating: "─", count: leading), theme.border)
            + Ansi.bold(Ansi.color(heading, colour))
            + Ansi.color(String(repeating: "─", count: dashes - leading) + "╮", theme.border)

        for (i, line) in lines.enumerated() {
            let pad = max(0, inner - Ansi.displayWidth(line))
            out += moveTo(top + 1 + i, left)
                + Ansi.color("│", theme.border) + " " + line + String(repeating: " ", count: pad) + " "
                + Ansi.color("│", theme.border)
        }
        out += moveTo(top + boxHeight - 1, left)
            + Ansi.color("╰" + String(repeating: "─", count: inner + 2) + "╯", theme.border)
        write(out)
    }

    private static func moveTo(_ row: Int, _ col: Int) -> String { "\u{1B}[\(row);\(col)H" }

    /// Ask before signalling, and mean it.
    ///
    /// The dialog names the process three ways — what it is, what it is running,
    /// and what it holds — because the one thing a confirmation must prevent is
    /// agreeing to kill a row you misread. Only `y` and Enter confirm; every
    /// other key cancels, so a stray keystroke can only ever be the safe answer.
    static func confirmKill(_ record: ProcessRecord, signal: Signal, theme: Theme) -> Bool {
        var lines: [String] = []
        lines.append(Ansi.bold(Ansi.color("\(signal.displayName)  →  \(record.name)", theme.danger))
            + Ansi.color("  pid \(record.pid)", theme.muted))
        let command = TableLayout.command(for: record)
        if !command.isEmpty {
            lines.append(Ansi.color(Format.truncate(command, to: 60), theme.command))
        }
        if !record.listeners.isEmpty {
            let ports = record.listeners.map(\.display).joined(separator: "  ")
            lines.append(Ansi.color(Format.truncate(ports, to: 60), theme.port))
        }
        if !record.isOwnedByCurrentUser {
            lines.append(Ansi.color("owned by \(record.user) — this may need sudo", theme.muted))
        }
        lines.append("")
        lines.append(Ansi.color("y", theme.accent) + Ansi.color(" send    ", theme.muted)
            + Ansi.color("any other key", theme.accent) + Ansi.color(" cancel", theme.muted))

        overlay(title: "confirm", lines: lines, theme: theme, accent: theme.danger)

        switch readKey() {
        case .char("y"), .char("Y"), .enter: return true
        default: return false
        }
    }

    /// The key reference (`?`), dismissed by any key.
    static func showHelp(_ groups: [(name: String, items: [String])], theme: Theme) {
        var lines: [String] = []
        for (index, group) in groups.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(Ansi.bold(Ansi.color(group.name, theme.accent)))
            for item in group.items {
                // Each item is "keys<gap>description", split on the run of
                // spaces the tables are written with so the two halves can be
                // coloured apart without the table carrying markup.
                guard let range = item.range(of: "  +", options: .regularExpression) else {
                    lines.append(Ansi.color(item, theme.muted))
                    continue
                }
                let keys = String(item[item.startIndex..<range.lowerBound])
                let text = String(item[range.upperBound...])
                lines.append(Ansi.color(Format.pad(keys, to: 14), theme.name)
                    + Ansi.color(text, theme.muted))
            }
        }
        overlay(title: "keys", lines: lines, theme: theme)
        _ = readKey()
    }
}
