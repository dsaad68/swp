import Foundation
import swpCore

/// The non-interactive half: printing a listing, and reporting on signals sent.
///
/// Kept apart from the picker so `swp -l` is a pure function of the scan plus a
/// width — which is what makes the redirected case (`swp | grep`) reliable
/// rather than a lucky path through the UI code.
enum Report {

    // MARK: - Listing

    /// Render the listing as lines, ready to print. Columns come from
    /// `TableLayout`, so a printed row and a picker row are the same row.
    /// - Parameter showCPU: include the CPU column. Off unless the caller
    ///   measured a rate — see `CPUSampler`; a column of dashes tells the
    ///   reader nothing and costs the command line six characters.
    static func lines(for processes: [ProcessRecord], theme: Theme, width: Int,
                      showCPU: Bool = false, showHeader: Bool = true,
                      now: Date = Date()) -> [String] {
        guard !processes.isEmpty else { return [] }
        let columns = TableLayout.columns(showCPU: showCPU)
        // Built once and used for both the sizing pass and the rows: a row's
        // cells include a command line that can run to thousands of characters.
        let cells = processes.map { TableLayout.cells(for: $0, columns: columns, now: now) }
        let widths = TableLayout.widths(forCells: cells, columns: columns, totalWidth: width)

        var out: [String] = []
        if showHeader {
            let header = TableLayout.plainHeader(widths: widths, columns: columns)
            out.append(Ansi.color(trimmed(header), theme.heading))
        }
        for (record, row) in zip(processes, cells) {
            let plain = TableLayout.plainRow(cells: row, widths: widths, columns: columns,
                                             padLast: false)
            out.append(TableLayout.styledRow(trimmed(plain), widths: widths, columns: columns,
                                             record: record, theme: theme))
        }
        return out
    }

    /// Drop trailing padding. It is invisible on a screen and real in a pipe,
    /// and `swp -l > before; swp -l > after; diff` should not see it.
    private static func trimmed(_ line: String) -> String {
        var text = line
        while text.hasSuffix(" ") { text.removeLast() }
        return text
    }

    // MARK: - JSON

    /// The listing as JSON: an array of objects, keys sorted, one line per
    /// value pretty-printed.
    ///
    /// Hand-built rather than `Codable` so the wire format is decided here, in
    /// the layer that owns output, instead of leaking into the core types where
    /// a later refactor could rename a field somebody's script depends on.
    static func json(for processes: [ProcessRecord]) -> String {
        // Pretty-printing an empty array gives "[\n\n]", which is valid and
        // silly. A script checking for "[]" should find one.
        guard !processes.isEmpty else { return "[]" }
        let formatter = ISO8601DateFormatter()
        let payload: [[String: Any]] = processes.map { record in
            var object: [String: Any] = [
                "pid": Int(record.pid),
                "ppid": Int(record.ppid),
                "name": record.name,
                "path": record.path,
                "user": record.user,
                "uid": Int(record.uid),
                "command": record.commandLine,
                "arguments": record.arguments,
                "listeners": record.listeners.map { listener in
                    [
                        "port": Int(listener.port),
                        "protocol": listener.netProtocol.rawValue,
                        "address": listener.address,
                        "family": listener.family.rawValue,
                    ] as [String: Any]
                },
            ]
            if let memory = record.memoryBytes { object["memory_bytes"] = Int(memory) }
            if let start = record.startTime { object["started"] = formatter.string(from: start) }
            return object
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    // MARK: - Signals

    /// One line describing what a process is, for a confirmation prompt or a
    /// result: `node (pid 14322) on 3000`.
    static func describe(_ record: ProcessRecord) -> String {
        let ports = record.listeners.isEmpty ? "" : " on \(record.listeners.portSummary())"
        return "\(record.name) (pid \(record.pid))\(ports)"
    }

    /// What to print after signalling. Successes name the process so a scripted
    /// run leaves a record of what it actually killed, and failures carry the
    /// reason — `sudo` is the answer often enough that `EPERM` says so outright.
    static func outcomeLine(_ outcome: Killer.Outcome, exited: Bool, theme: Theme) -> String {
        let subject = outcome.name.isEmpty ? "pid \(outcome.pid)" : "\(outcome.name) (pid \(outcome.pid))"
        guard let failure = outcome.failure else {
            let verb = exited ? "killed" : "signalled"
            let tail = exited ? "" : " — still running"
            return Ansi.color("\(verb) \(subject) with \(outcome.signal.displayName)\(tail)",
                              exited ? theme.success : theme.muted)
        }
        return Ansi.color("could not signal \(subject): \(failure.message)", theme.danger)
    }
}
