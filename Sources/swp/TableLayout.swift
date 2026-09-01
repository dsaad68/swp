import Foundation
import swpCore

/// The one definition of the process table: which columns exist, how wide they
/// are, and how a row is painted.
///
/// Shared by the printed listing and the picker so the two cannot drift. It
/// also buys the picker something subtler: because a row is built by padding
/// cells and joining them, the plain text of a row is exactly what the terminal
/// shows — so a fuzzy match's character offsets, taken against that plain text,
/// land on the right cells when the row is drawn.
enum TableLayout {

    static let headers = ["PORT", "PID", "USER", "MEM", "UP", "NAME", "COMMAND"]

    /// Columns whose values are numbers, and so read better right-aligned.
    private static let rightAligned: Set<Int> = [1, 3]

    /// Ceilings for the auto-sized columns.
    ///
    /// Without them one outlier sets the width for everybody: a browser helper
    /// holding twenty ports made the PORT column twenty characters wide for a
    /// table whose every other row needed four, and pushed the command line off
    /// the screen. The outlier is truncated instead — its full detail is one
    /// keystroke away in the picker, and the columns stay readable.
    private static let maxWidths = [14, 8, 12, 6, 5, 26, Int.max]

    /// Floors for the shrink pass, and the order it gives ground in.
    ///
    /// NAME goes first because it is the widest and the most redundant — the
    /// command beside it usually says the same thing — then USER, which on a
    /// single-user machine is the same word on every row, then PORT, which is
    /// the last thing anyone wants cut.
    private static let minWidths = [5, 3, 3, 4, 2, 6, 8]
    private static let shrinkOrder = [5, 2, 0]

    /// Two spaces between columns: one is too tight to read a port off at a
    /// glance, three wastes the width the command column wants.
    static let gap = "  "

    static func cells(for record: ProcessRecord, now: Date = Date()) -> [String] {
        [
            record.listeners.isEmpty ? "-" : record.listeners.portSummary(),
            String(record.pid),
            record.user,
            Format.bytes(record.memoryBytes),
            Format.elapsed(since: record.startTime, now: now),
            record.name,
            command(for: record),
        ]
    }

    /// The command column.
    ///
    /// argv[0] is dropped when it only repeats the NAME column beside it, which
    /// is the common case (`bun --hot serve.ts`). It is kept when it does not:
    /// a process that rewrote its own argv is telling you what it thinks it is,
    /// and "Raycast Backend" against the name `node` is the whole answer to why
    /// node is holding a port. With no arguments at all the path stands in, and
    /// with neither — another user's process, without root — the name does, in
    /// brackets, so the cell is never blank.
    static func command(for record: ProcessRecord) -> String {
        // Empty entries are real: an argv rewritten in place is NUL-padded, and
        // joining those unfiltered produced a cell of nothing but spaces.
        let arguments = record.arguments.filter { !$0.isEmpty }
        guard let first = arguments.first else { return fallback(for: record) }
        if (first as NSString).lastPathComponent != record.name {
            return arguments.joined(separator: " ")
        }
        let rest = arguments.dropFirst().joined(separator: " ")
        return rest.isEmpty ? fallback(for: record) : rest
    }

    private static func fallback(for record: ProcessRecord) -> String {
        record.path.isEmpty ? "[\(record.name)]" : record.path
    }

    /// Size each column to its widest value and give the remainder to the last.
    ///
    /// Sized over *every* record rather than over the ones currently shown, so
    /// the columns hold still while a filter is being typed. A table that
    /// re-flows on each keystroke is unreadable at typing speed, and the width
    /// it settles on is not worth that.
    static func widths(for records: [ProcessRecord], totalWidth: Int,
                       now: Date = Date()) -> [Int] {
        widths(forCells: records.map { cells(for: $0, now: now) }, totalWidth: totalWidth)
    }

    /// The same sizing, over cells the caller has already built.
    ///
    /// Worth its own entry point because building a row's cells means joining a
    /// command line that can run to thousands of characters, and a caller that
    /// sizes the table and then draws it would otherwise do that twice.
    static func widths(forCells rows: [[String]], totalWidth: Int) -> [Int] {
        var widths = headers.map { Ansi.displayWidth($0) }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count - 1 {
                widths[i] = min(maxWidths[i], max(widths[i], Ansi.displayWidth(cell)))
            }
        }
        // On a narrow terminal the fixed columns can already be wider than the
        // whole frame, and the last column's floor cannot fix that — the row
        // would simply run past the border. So give ground in a fixed order
        // until it fits, rather than letting the layout overflow and be cut.
        var fixed = widths.dropLast().reduce(0) { $0 + $1 + gap.count }
        let last = widths.count - 1
        for column in shrinkOrder where fixed + minWidths[last] > totalWidth {
            let give = min(widths[column] - minWidths[column],
                           fixed + minWidths[last] - totalWidth)
            guard give > 0 else { continue }
            widths[column] -= give
            fixed -= give
        }
        // A terminal narrower than the floors is not drawable at all; the frame
        // truncates what is left, which is the only remaining answer.
        widths[last] = max(minWidths[last], totalWidth - fixed)
        return widths
    }

    /// The row as plain text: cells truncated and padded to `widths`, joined.
    ///
    /// Every cell is cut to its column, not just the last one, because the
    /// ceilings above mean any column can now be narrower than its widest
    /// value. Trailing padding on the last column is left on: the picker paints
    /// its selection band across the whole row, and a short command would
    /// otherwise leave a hole in it.
    /// - Parameter padLast: pad the final column out to its width. The picker
    ///   wants that — its selection band is painted across the whole row, and a
    ///   short command would leave a hole in it. A printed listing does not:
    ///   with output redirected the last column is thousands of columns wide
    ///   (nothing is truncated in a pipe), and padding every row out to it and
    ///   then trimming the spaces back off cost 380 ms on a full `-a` listing.
    static func plainRow(cells: [String], widths: [Int], padLast: Bool = true) -> String {
        var parts: [String] = []
        for (i, cell) in cells.enumerated() {
            let text = Format.truncate(cell, to: widths[i])
            if i == cells.count - 1, !padLast {
                parts.append(text)
            } else {
                parts.append(rightAligned.contains(i) ? Format.padLeft(text, to: widths[i])
                                                      : Format.pad(text, to: widths[i]))
            }
        }
        return parts.joined(separator: gap)
    }

    /// The header row as plain text, aligned the same way the values are.
    static func plainHeader(widths: [Int]) -> String {
        plainRow(cells: headers, widths: widths)
    }

    /// Where each column starts within a plain row, so a character offset can
    /// be traced back to the column it fell in.
    static func columnStarts(_ widths: [Int]) -> [Int] {
        var starts: [Int] = []
        var cursor = 0
        for width in widths {
            starts.append(cursor)
            cursor += width + gap.count
        }
        return starts
    }

    /// Paint a plain row, colouring each column and picking out `highlight`
    /// offsets — the characters a fuzzy filter matched.
    ///
    /// Emitted as *runs*: a style is written once and then only when it
    /// changes. Writing one per character is the obvious way to do it and cost
    /// 40 KB a frame — more than a pty hands over in one piece, so the frame
    /// arrived visibly in halves — where the run version is about 1 KB for the
    /// same row. The highlight set is what makes runs non-trivial: a match can
    /// break a column into three runs, so the boundary test is the style, not
    /// the column.
    static func styledRow(_ plain: String, widths: [Int], record: ProcessRecord,
                          theme: Theme, highlight: Set<Int> = [],
                          background: Ansi.Color? = nil) -> String {
        guard Ansi.colorEnabled else { return plain }
        let starts = columnStarts(widths)
        let exposed = record.listeners.contains(where: \.isWildcard)
        let colors: [Ansi.Color] = [
            exposed ? theme.exposed : theme.port,
            theme.pid, theme.muted, theme.muted, theme.muted, theme.name, theme.command,
        ]
        let backgroundCodes = background.map { Ansi.bg($0) } ?? []

        var out = ""
        var pending = ""
        var currentCodes: [Int]?
        var column = 0

        func flush() {
            guard !pending.isEmpty, let codes = currentCodes else { return }
            out += Ansi.code(codes) + pending
            pending = ""
        }

        for (index, character) in plain.enumerated() {
            while column + 1 < starts.count, index >= starts[column + 1] { column += 1 }
            let lit = highlight.contains(index)
            var codes = Ansi.fg(lit ? theme.accent : colors[column])
            if lit { codes.append(1) }
            codes += backgroundCodes
            if codes != currentCodes {
                flush()
                currentCodes = codes
            }
            pending.append(character)
        }
        flush()
        return out + Ansi.reset
    }
}
