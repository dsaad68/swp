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

    /// A column, and everything about it in one place.
    ///
    /// Previously this was five arrays indexed in parallel — headers, ceilings,
    /// floors, alignment, shrink order — which worked exactly as long as the
    /// set of columns was fixed. CPU is optional (it costs a second sample, so
    /// it appears only when asked for), and inserting a conditional column into
    /// parallel arrays is how off-by-one bugs are made.
    enum Column: CaseIterable {
        case port, pid, user, cpu, memory, uptime, name, command

        var header: String {
            switch self {
            case .port:    return "PORT"
            case .pid:     return "PID"
            case .user:    return "USER"
            case .cpu:     return "CPU"
            case .memory:  return "MEM"
            case .uptime:  return "UP"
            case .name:    return "NAME"
            case .command: return "COMMAND"
            }
        }

        /// Numbers read better right-aligned, so their digits line up.
        var isNumeric: Bool {
            switch self {
            case .pid, .cpu, .memory: return true
            default: return false
            }
        }

        /// Ceiling for the auto-sized width.
        ///
        /// Without one, a single outlier sets the width for everybody: a
        /// browser helper holding twenty ports made the PORT column twenty
        /// characters wide for a table whose every other row needed four, and
        /// pushed the command line off the screen.
        var maxWidth: Int {
            switch self {
            case .port:    return 14
            case .pid:     return 8
            case .user:    return 12
            case .cpu:     return 6
            case .memory:  return 6
            case .uptime:  return 5
            case .name:    return 26
            case .command: return .max
            }
        }

        /// Floor for the shrink pass.
        var minWidth: Int {
            switch self {
            case .port:    return 5
            case .pid:     return 3
            case .user:    return 3
            case .cpu:     return 4
            case .memory:  return 4
            case .uptime:  return 2
            case .name:    return 6
            case .command: return 8
            }
        }

        func cell(for record: ProcessRecord, now: Date) -> String {
            switch self {
            case .port:    return record.listeners.isEmpty ? "-" : record.listeners.portSummary()
            case .pid:     return String(record.pid)
            case .user:    return record.user
            case .cpu:     return Format.percent(record.cpuPercent)
            case .memory:  return Format.bytes(record.memoryBytes)
            case .uptime:  return Format.elapsed(since: record.startTime, now: now)
            case .name:    return record.name
            case .command: return TableLayout.command(for: record)
            }
        }
    }

    /// The columns to draw. CPU is left out unless the caller has a rate to put
    /// in it — a column of dashes tells the reader nothing and costs the
    /// command line six characters.
    static func columns(showCPU: Bool) -> [Column] {
        Column.allCases.filter { $0 != .cpu || showCPU }
    }

    /// The order columns give ground in when the terminal is too narrow.
    ///
    /// NAME goes first because it is the widest and the most redundant — the
    /// command beside it usually says the same thing — then USER, which on a
    /// single-user machine is the same word on every row, then PORT, which is
    /// the last thing anyone wants cut.
    private static let shrinkOrder: [Column] = [.name, .user, .port]

    /// Two spaces between columns: one is too tight to read a port off at a
    /// glance, three wastes the width the command column wants.
    static let gap = "  "

    static func cells(for record: ProcessRecord, columns: [Column],
                      now: Date = Date()) -> [String] {
        columns.map { $0.cell(for: record, now: now) }
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
    static func widths(for records: [ProcessRecord], columns: [Column],
                       totalWidth: Int, now: Date = Date()) -> [Int] {
        widths(forCells: records.map { cells(for: $0, columns: columns, now: now) },
               columns: columns, totalWidth: totalWidth)
    }

    /// The same sizing, over cells the caller has already built.
    ///
    /// Worth its own entry point because building a row's cells means joining a
    /// command line that can run to thousands of characters, and a caller that
    /// sizes the table and then draws it would otherwise do that twice.
    static func widths(forCells rows: [[String]], columns: [Column],
                       totalWidth: Int) -> [Int] {
        var widths = columns.map { Ansi.displayWidth($0.header) }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count - 1 {
                widths[i] = min(columns[i].maxWidth, max(widths[i], Ansi.displayWidth(cell)))
            }
        }

        // On a narrow terminal the fixed columns can already be wider than the
        // whole frame, and the last column's floor cannot fix that — the row
        // would simply run past the border. So give ground in a fixed order
        // until it fits, rather than letting the layout overflow and be cut.
        var fixed = widths.dropLast().reduce(0) { $0 + $1 + gap.count }
        let last = widths.count - 1
        for column in shrinkOrder {
            guard let i = columns.firstIndex(of: column), i != last else { continue }
            guard fixed + columns[last].minWidth > totalWidth else { break }
            let give = min(widths[i] - column.minWidth,
                           fixed + columns[last].minWidth - totalWidth)
            guard give > 0 else { continue }
            widths[i] -= give
            fixed -= give
        }
        // A terminal narrower than the floors is not drawable at all; the frame
        // truncates what is left, which is the only remaining answer.
        widths[last] = max(columns[last].minWidth, totalWidth - fixed)
        return widths
    }

    /// The row as plain text: cells truncated and padded to `widths`, joined.
    ///
    /// - Parameter padLast: pad the final column out to its width. The picker
    ///   wants that — its selection band is painted across the whole row, and a
    ///   short command would leave a hole in it. A printed listing does not:
    ///   with output redirected the last column is thousands of columns wide
    ///   (nothing is truncated in a pipe), and padding every row out to it and
    ///   then trimming the spaces back off cost 380 ms on a full `-a` listing.
    static func plainRow(cells: [String], widths: [Int], columns: [Column],
                         padLast: Bool = true) -> String {
        var parts: [String] = []
        for (i, cell) in cells.enumerated() {
            let text = Format.truncate(cell, to: widths[i])
            if i == cells.count - 1, !padLast {
                parts.append(text)
            } else {
                parts.append(columns[i].isNumeric ? Format.padLeft(text, to: widths[i])
                                                  : Format.pad(text, to: widths[i]))
            }
        }
        return parts.joined(separator: gap)
    }

    /// The header row as plain text, aligned the same way the values are.
    static func plainHeader(widths: [Int], columns: [Column]) -> String {
        plainRow(cells: columns.map(\.header), widths: widths, columns: columns)
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
    static func styledRow(_ plain: String, widths: [Int], columns: [Column],
                          record: ProcessRecord, theme: Theme,
                          highlight: Set<Int> = [], background: Ansi.Color? = nil) -> String {
        guard Ansi.colorEnabled else { return plain }
        let starts = columnStarts(widths)
        let exposed = record.listeners.contains(where: \.isWildcard)
        let backgroundCodes = background.map { Ansi.bg($0) } ?? []

        func colour(_ column: Column) -> Ansi.Color {
            switch column {
            case .port:    return exposed ? theme.exposed : theme.port
            case .pid:     return theme.pid
            case .name:    return theme.name
            case .command: return theme.command
            // A busy process is the reason someone sorted by CPU, so it is
            // picked out rather than left in the same grey as the columns
            // nobody is scanning.
            case .cpu:     return (record.cpuPercent ?? 0) >= 10 ? theme.exposed : theme.muted
            case .user, .memory, .uptime: return theme.muted
            }
        }

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
            var codes = Ansi.fg(lit ? theme.accent : colour(columns[column]))
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
