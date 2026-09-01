import Foundation
import swpCore

extension ProcessMenu {

    /// Build one frame: the header (a wordmark and a boxed filter field, or a
    /// single title line on a short terminal), the column header, the rows, and
    /// a hint line — all inside one rounded border.
    ///
    /// Pure: it reads the menu's state and the size it is handed, and touches no
    /// terminal. That is what lets a test assert on a whole frame rather than on
    /// the pieces that make one.
    func frame(size: Terminal.Size, viewport: Int) -> [String] {
        let width = forcedWidth ?? size.cols
        let inner = max(20, width - 4)
        let chrome = Chrome(size: size, width: width)

        var lines: [String] = []
        lines.append(border(top: true, width: width))
        if chrome.full {
            lines.append(boxed("", inner: inner))
            for row in wordmarkRows() { lines.append(boxed("  " + row, inner: inner)) }
            // Indented to sit under the wordmark rather than under the border,
            // so the two read as one masthead.
            lines.append(boxed("  " + subtitleLine(inner: inner - 2), inner: inner))
            lines.append(boxed("", inner: inner))
            for row in filterBoxRows(inner: inner) { lines.append(boxed(row, inner: inner)) }
        } else {
            lines.append(boxed(titleLine(inner: inner), inner: inner))
            lines.append(boxed(compactFilterLine(inner: inner), inner: inner))
        }
        // Truncated like a row: the shrink pass keeps the columns inside the
        // frame in every realistic case, and this is what holds when the
        // terminal is narrower than the floors themselves.
        let header = TableLayout.plainHeader(widths: columnWidths, columns: visibleColumns)
        lines.append(boxed(Ansi.color(Format.truncate(header, to: inner), theme.heading),
                           inner: inner))

        let rows = visibleRows
        if rows.isEmpty {
            lines.append(boxed(Ansi.color(emptyMessage, theme.muted), inner: inner))
            lines.append(contentsOf: (1..<max(1, viewport)).map { _ in boxed("", inner: inner) })
        } else {
            for offset in 0..<viewport {
                let index = topIndex + offset
                guard index < rows.count else { lines.append(boxed("", inner: inner)); continue }
                lines.append(boxed(row(rows[index], selected: index == selectedIndex, inner: inner),
                                   inner: inner))
            }
        }

        lines.append(boxed(hintLine(inner: inner), inner: inner))
        lines.append(border(top: false, width: width))
        return lines
    }

    // MARK: - Chrome

    /// `╭──────────╮` / `╰──────────╯`. Rounded corners, matching the register
    /// the rest of the chrome is drawn in.
    private func border(top: Bool, width: Int) -> String {
        let line = String(repeating: "─", count: max(0, width - 2))
        return Ansi.color(top ? "╭\(line)╮" : "╰\(line)╯", theme.border)
    }

    /// Wrap already-styled content in the side borders, padding it to the inner
    /// width. Padding is measured on display width, so a coloured cell is not
    /// counted as its escape bytes.
    private func boxed(_ content: String, inner: Int) -> String {
        let bar = Ansi.color("│", theme.border)
        let visible = Ansi.displayWidth(content)
        let padding = visible >= inner ? "" : String(repeating: " ", count: inner - visible)
        return "\(bar) \(content)\(padding) \(bar)"
    }

    /// The compact header's one line, for a terminal too short for the
    /// wordmark: `swp  ports  all users · by port      3 of 25 listening`.
    ///
    /// The count sits on the right and says both halves of the truth when a
    /// filter is on: how many are shown, and how many there were. "3" alone
    /// reads as a machine with three servers on it.
    private func titleLine(inner: Int) -> String {
        let facets = [restrictedToMe ? "mine" : "all users", "by \(sort.label)"]
        let left = Ansi.bold(Ansi.color("swp", theme.accent))
            + "  " + Ansi.color(portsOnly ? "ports" : "everything", theme.heading)
            + "  " + Ansi.color(facets.joined(separator: " · "), theme.muted)

        let noun = portsOnly ? "listening" : "processes"
        let count = visibleRows.count == totalCount
            ? "\(totalCount) \(noun)"
            : "\(visibleRows.count) of \(totalCount) \(noun)"
        let right = Ansi.color(count, theme.muted)

        let used = Ansi.displayWidth(left) + Ansi.displayWidth(right)
        guard used < inner else { return Format.truncate(left, to: inner) }
        return left + String(repeating: " ", count: inner - used) + right
    }

    /// The compact header's filter line — the same field as the boxed one, on
    /// a terminal that cannot spare three rows for a box. Focused, it shows a
    /// drawn caret: the real cursor is hidden for the whole frame, and one
    /// parked at the end of the field would be painted over by the next.
    private func compactFilterLine(inner: Int) -> String {
        let prompt = Ansi.color("❯", isSearching ? theme.accent : theme.border)
        guard !filterText.isEmpty || isSearching else {
            return "\(prompt) \(Ansi.color("press / to filter", theme.muted))"
        }
        let text = Ansi.color(Format.truncate(filterText, to: max(1, inner - 4)), theme.accent)
        let caret = isSearching ? Ansi.color("▏", theme.accent) : ""
        return "\(prompt) \(text)\(caret)"
    }

    /// One process row, with the selection band and the fuzzy highlights.
    private func row(_ row: Row, selected: Bool, inner: Int) -> String {
        // The label is padded to the full content width already, so the
        // selection background covers the row edge to edge rather than stopping
        // where the command happens to end.
        let plain = Format.pad(Format.truncate(row.label, to: inner), to: inner)
        let styled = TableLayout.styledRow(plain, widths: columnWidths, columns: visibleColumns,
                                           record: row.record, theme: theme,
                                           highlight: Set(row.indices),
                                           background: selected ? theme.selectionBg : nil)
        return styled
    }

    /// What the footer says. A status message (the result of the last signal)
    /// takes the line while it is fresh, because it is the answer to the thing
    /// the user just did; the key hints come back afterwards.
    private func hintLine(inner: Int) -> String {
        if let message = statusMessage {
            return Ansi.color(Format.truncate(message, to: inner), theme.success)
        }
        if portsAreIncomplete, portsOnly {
            // Said once, in the place a question would be asked, rather than as
            // a banner: the answer shown is right for your own processes and
            // silently partial for everyone else's, and that is worth a line.
            return Ansi.color(Format.truncate(
                "showing your processes' ports — run sudo swp to see every user's · ? for keys",
                to: inner
            ), theme.muted)
        }
        let hints = [
            "↑↓ move", "/ filter", "⏎ \(signal.displayName)", "X \(Signal.kill.displayName)",
            portsOnly ? "a all" : "a ports", "s sort", "? keys", "q quit",
        ]
        return Ansi.color(Format.truncate(hints.joined(separator: " · "), to: inner), theme.muted)
    }

    /// Why the list is empty, in the terms of whatever made it empty. "No
    /// matches" when a filter is on, and otherwise the real reason — which on
    /// macOS is usually that the ports being looked for belong to someone else.
    private var emptyMessage: String {
        if !filterText.isEmpty { return "no process matches \"\(filterText)\"" }
        // A query given on the command line is the most likely reason the list
        // is empty, and it stays the reason after a kill empties it — which is
        // exactly when the sudo advice below would be read as a failure.
        if let query = queryDescription { return "nothing matches \(query)" }
        if portsOnly {
            return portsAreIncomplete
                ? "nothing of yours is listening — other users' ports need sudo swp"
                : "nothing is listening. Press a for every process."
        }
        return "no processes are running, which cannot be true — please report this"
    }

    private var portsOnly: Bool { !showsPortless }
}
