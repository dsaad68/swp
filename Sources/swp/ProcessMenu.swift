import Foundation
import swpCore

/// The interactive list: scan, filter, pick, signal, repeat.
///
/// The loop owns the terminal but not the terminal's mechanics — those are
/// `Terminal`'s — and not the frame's appearance, which is `ProcessMenu+Draw`'s.
/// What lives here is the state a keystroke changes and the rules for what a
/// keystroke means, which is the part worth being able to read in one sitting.
struct ProcessMenu {

    /// A row: the process plus the character offsets the filter matched, so the
    /// draw pass can highlight them without matching a second time.
    struct Row {
        var record: ProcessRecord
        /// The row as plain text, already padded into columns. Both the thing
        /// the filter matched against and the thing the draw pass paints, which
        /// is what makes the match offsets line up with what is on screen.
        var label: String
        /// Character offsets in `label` the filter matched.
        var indices: [Int]
    }

    var theme: Theme
    var signal: Signal
    var sort: ProcessSort
    var includePortless: Bool
    var user: uid_t?
    /// The query typed on the command line, applied before anything is shown.
    /// Kept separate from the live filter so `Esc` clears what the user typed
    /// in the box without discarding what they asked for on the way in.
    var initialQuery: Query
    /// Keep only the first `limit` rows after sorting, when `--top` was given.
    /// Named `limit` rather than `top` because `top` here is the scroll offset;
    /// two different `top`s in one loop is a bug waiting for a tired reader.
    var limit: Int?
    /// Fixed width for testing; nil means ask the terminal each frame.
    var forcedWidth: Int?

    // MARK: - State

    var all: [ProcessRecord] = []
    /// Every record in display order, each with its rendered row text — the
    /// input the filter runs over. Rebuilt when the *list* changes (a scan, a
    /// new sort order, a resize), never when a key is typed.
    var candidates: [(record: ProcessRecord, label: String)] = []
    var rows: [Row] = []
    /// Column widths, recomputed on each scan from every record — not from the
    /// filtered ones, so the table holds still while a filter is typed.
    var widths: [Int] = []
    /// Which columns are drawn. The picker always shows CPU: it re-scans every
    /// two seconds anyway, so the second sample a rate needs is already being
    /// taken and the column costs nothing.
    var columns = TableLayout.columns(showCPU: true)
    var selected = 0
    var top = 0
    var filter = ""
    /// Whether keys type into the filter box or drive the list. Modal, so a
    /// query may contain `q`, `x` and `a` like any other letter — and so the
    /// letter that kills cannot be typed by accident while searching.
    var searching = false
    var portsIncomplete = false
    /// Carries the previous scan's CPU counters so each refresh can turn them
    /// into a rate. Owned by the menu rather than the scanner because a rate
    /// belongs to a *sequence* of scans, and only the thing that repeats them
    /// knows what the interval was.
    var cpu = CPUSampler()
    /// A line shown in the footer until it expires: what the last signal did.
    var message: (text: String, until: Date)?

    init(theme: Theme, signal: Signal, sort: ProcessSort, includePortless: Bool,
         user: uid_t?, initialQuery: Query, limit: Int? = nil, forcedWidth: Int? = nil) {
        self.theme = theme
        self.signal = signal
        self.sort = sort
        self.includePortless = includePortless
        self.user = user
        self.initialQuery = initialQuery
        self.limit = limit
        self.forcedWidth = forcedWidth
    }

    /// How often the list re-scans itself.
    ///
    /// A scan costs about a millisecond and a half, so this could be far more
    /// frequent — but a list that reorders under the cursor is a list you
    /// cannot safely act on, and two seconds is slow enough that a row is still
    /// where the eye left it while being fast enough that a server you just
    /// started shows up before you go looking for it.
    private static let refreshInterval: TimeInterval = 2.0

    // MARK: - Loop

    /// Run until the user quits. Returns the process exit code.
    mutating func run() -> Int32 {
        refresh()
        // A rate needs two readings, so the first frame has no CPU figures to
        // show. Rather than leave the column dashed for a full interval, bring
        // the *second* scan forward: the first frame paints immediately, and a
        // quarter of a second later the numbers arrive. Only the first interval
        // is shortened; after that the two-second cadence holds.
        var lastScan = Date().addingTimeInterval(0.25 - Self.refreshInterval)
        var needsRedraw = true
        var lastSize = Terminal.Size(rows: 0, cols: 0)

        Terminal.hideCursor()
        defer { Terminal.showCursor() }

        while true {
            let size = Terminal.size()
            if Terminal.didResize || size != lastSize {
                Terminal.didResize = false
                let widthChanged = size.cols != lastSize.cols
                lastSize = size
                // The column widths and the rendered rows are sized to the
                // terminal, and they are no longer rebuilt on every keystroke —
                // so a resize has to say so, or the table would keep the old
                // width until the next scan up to two seconds later.
                if widthChanged {
                    rebuildCandidates()
                    applyFilter()
                }
                needsRedraw = true
            }

            if Date().timeIntervalSince(lastScan) >= Self.refreshInterval {
                lastScan = Date()
                refresh()
                needsRedraw = true
            }
            if let message, message.until < Date() {
                self.message = nil
                needsRedraw = true
            }

            let viewport = listRows(for: size)
            clampSelection(viewport: viewport)

            if needsRedraw {
                Terminal.render(frame(size: size, viewport: viewport))
                needsRedraw = false
            }

            // The poll interval is what makes the clock-driven work above
            // happen at all: with a blocking read, a list would sit stale until
            // the user touched a key.
            guard let key = Terminal.readKey(timeoutMs: 120) else { continue }
            needsRedraw = true

            switch handle(key, viewport: viewport) {
            case .quit: return 0
            case .stay: continue
            }
        }
    }

    // MARK: - Data

    /// Re-scan, keeping the cursor on the same process if it is still there.
    ///
    /// By pid, not by index: between two scans a process above the cursor can
    /// exit and every row below it shifts up one. Following the index would
    /// move the selection onto a neighbour silently, which in this program
    /// means the next keystroke signals something the user never chose.
    mutating func refresh() {
        let keep = rows.indices.contains(selected) ? rows[selected].record.pid : nil
        var result = ProcessScanner.scan(
            .init(includePortless: includePortless, user: user)
        )
        cpu.annotate(&result.processes)
        all = initialQuery.filter(result.processes)
        if let limit, all.count > limit {
            // Sorted before it is cut: the top N of an unsorted list is
            // arbitrary. Re-cut on every scan and on every `s`, so the N rows
            // are always the N the current order says they are.
            all = Array(all.sorted(by: sort).prefix(limit))
        }
        portsIncomplete = result.portsIncomplete
        rebuildCandidates()
        applyFilter()
        if let keep, let at = rows.firstIndex(where: { $0.record.pid == keep }) { selected = at }
    }

    /// Sort the records and render each one's row text.
    ///
    /// Split out from `applyFilter` because none of it depends on the filter,
    /// and all of it used to run on every keystroke: with `-a` on a busy
    /// machine that was a 1000-element sort of an already-sorted array (1.3 ms)
    /// plus a thousand command lines joined and padded, thrown away and rebuilt
    /// on the next letter. It changes when the list does — a scan, a new sort
    /// order, a resize — so that is when it runs.
    mutating func rebuildCandidates() {
        let now = Date()
        widths = TableLayout.widths(for: all, columns: columns, totalWidth: contentWidth, now: now)
        candidates = all.sorted(by: sort).map { record in
            (record, TableLayout.plainRow(
                cells: TableLayout.cells(for: record, columns: columns, now: now),
                widths: widths, columns: columns
            ))
        }
    }

    mutating func applyFilter() {
        rows = FuzzyMatch.filterAndSort(candidates, query: filter, label: \.label)
            .map { Row(record: $0.item.record, label: $0.item.label, indices: $0.indices) }
        // A filter that just got narrower can leave the cursor past the end;
        // clamping happens in the loop, but the top must not be left stranded
        // below it or the first frame after a keystroke scrolls for no reason.
        if selected >= rows.count { selected = max(0, rows.count - 1) }
        if top > selected { top = selected }
    }

    mutating func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selected = max(0, min(rows.count - 1, selected + delta))
    }

    mutating func clampSelection(viewport: Int) {
        selected = max(0, min(selected, max(0, rows.count - 1)))
        if selected < top { top = selected }
        if selected >= top + viewport { top = selected - viewport + 1 }
        top = max(0, min(top, max(0, rows.count - viewport)))
    }

    mutating func note(_ text: String) {
        message = (text, Date().addingTimeInterval(3))
    }

    // MARK: - Acting

    /// Confirm, signal, then say what happened.
    ///
    /// The confirmation is not optional here even though `--yes` exists for the
    /// command line: on the command line the user typed the target and can read
    /// it back before pressing return, and in the picker the target is wherever
    /// a cursor happens to be sitting.
    mutating func act(with signal: Signal) {
        guard rows.indices.contains(selected) else { return }
        let record = rows[selected].record

        guard Terminal.confirmKill(record, signal: signal, theme: theme) else {
            note("cancelled")
            return
        }
        let (outcome, exited) = Killer.sendAndConfirm(signal, to: record)
        if let failure = outcome.failure {
            note("\(record.name): \(failure.message)")
        } else if exited {
            note("killed \(record.name) (pid \(record.pid)) with \(signal.displayName)")
        } else {
            note("\(signal.displayName) sent — \(record.name) is still running")
        }
        refresh()
    }

    mutating func copyPid() {
        guard rows.indices.contains(selected) else { return }
        let pid = String(rows[selected].record.pid)
        Terminal.copyToClipboard(pid)
        note("copied pid \(pid)")
    }

    // MARK: - Layout

    /// The chrome for a given terminal, so the draw pass and the click handler
    /// agree on where row zero is. An off-by-one between them would put the
    /// cursor on a different row than the one under the pointer — and the next
    /// keystroke acts on the cursor.
    func chrome(for size: Terminal.Size) -> Chrome {
        Chrome(size: size, width: forcedWidth ?? size.cols)
    }

    private func listRows(for size: Terminal.Size) -> Int {
        let chrome = chrome(for: size)
        return max(1, size.rows - chrome.headerLines - chrome.footerLines)
    }

    // Accessors the draw extension reads. The stored state above is internal
    // rather than private because the input handling lives in
    // `ProcessMenu+Input.swift` and the drawing in two more files — the same
    // split termdown uses for its pager, and the reason the file-length ceiling
    // is worth having. These stay as read-only names so the drawing code has no
    // way to write what it is only meant to render.
    var visibleRows: [Row] { rows }
    var selectedIndex: Int { selected }
    var topIndex: Int { top }
    var filterText: String { filter }
    var isSearching: Bool { searching }
    var statusMessage: String? { message.map(\.text) }
    var totalCount: Int { all.count }
    var portsAreIncomplete: Bool { portsIncomplete }
    var restrictedToMe: Bool { user != nil }

    /// The command-line query in the terms the user typed it, or nil if there
    /// was none. Used to explain an empty list, where "nothing is listening" is
    /// both wrong and alarming when the truth is "nothing matches 3000".
    var queryDescription: String? {
        guard !initialQuery.isEmpty else { return nil }
        var parts: [String] = []
        if !initialQuery.ports.isEmpty {
            parts.append("port " + initialQuery.ports.map(String.init).joined(separator: ", "))
        }
        if !initialQuery.pids.isEmpty {
            parts.append("pid " + initialQuery.pids.map(String.init).joined(separator: ", "))
        }
        parts.append(contentsOf: initialQuery.terms.map { "\"\($0)\"" })
        return parts.joined(separator: " and ")
    }
    var columnWidths: [Int] { widths }
    var visibleColumns: [TableLayout.Column] { columns }
    var showsPortless: Bool { includePortless }

    /// Load a fixed set of records instead of scanning. Tests only: it is the
    /// seam that lets a whole frame be asserted on without the machine's real
    /// process table underneath it, which would make any such test a coin toss.
    mutating func loadForTesting(_ records: [ProcessRecord]) {
        all = initialQuery.filter(records)
        rebuildCandidates()
        applyFilter()
    }

    /// Type into the filter box, as `/` followed by keystrokes would. Tests only.
    mutating func filterForTesting(_ text: String) {
        filter = text
        applyFilter()
    }

    /// Width available inside the border: one column of border and one of
    /// padding on each side.
    var contentWidth: Int { max(20, (forcedWidth ?? Terminal.size().cols) - 4) }
}
