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
    /// Fixed width for testing; nil means ask the terminal each frame.
    var forcedWidth: Int?

    // MARK: - State

    private var all: [ProcessRecord] = []
    /// Every record in display order, each with its rendered row text — the
    /// input the filter runs over. Rebuilt when the *list* changes (a scan, a
    /// new sort order, a resize), never when a key is typed.
    private var candidates: [(record: ProcessRecord, label: String)] = []
    private var rows: [Row] = []
    /// Column widths, recomputed on each scan from every record — not from the
    /// filtered ones, so the table holds still while a filter is typed.
    private var widths: [Int] = []
    private var selected = 0
    private var top = 0
    private var filter = ""
    /// Whether keys type into the filter box or drive the list. Modal, so a
    /// query may contain `q`, `x` and `a` like any other letter — and so the
    /// letter that kills cannot be typed by accident while searching.
    private var searching = false
    private var portsIncomplete = false
    /// A line shown in the footer until it expires: what the last signal did.
    private var message: (text: String, until: Date)?

    init(theme: Theme, signal: Signal, sort: ProcessSort, includePortless: Bool,
         user: uid_t?, initialQuery: Query, forcedWidth: Int? = nil) {
        self.theme = theme
        self.signal = signal
        self.sort = sort
        self.includePortless = includePortless
        self.user = user
        self.initialQuery = initialQuery
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
        var lastScan = Date()
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

    private enum Step { case stay, quit }

    private mutating func handle(_ key: Terminal.Key, viewport: Int) -> Step {
        switch key {
        // ── Always active: navigation cannot collide with typing. ──
        case .up:
            move(by: -1)
        case .down:
            move(by: 1)
        case .pageUp:
            move(by: -viewport)
        case .pageDown:
            move(by: viewport)
        case .home:
            selected = 0
        case .end:
            selected = max(0, rows.count - 1)
        case .mouseScroll(let delta):
            move(by: Terminal.coalesceScroll(delta))
        case .mouseClick(_, let y):
            // Selects only, never acts. A double-click that killed something
            // would be a mis-click away from a lost process, and the mouse is
            // the one input with no confirmation habit attached to it.
            let offset = y - 1 - chrome(for: Terminal.size()).headerLines
            if offset >= 0, offset < viewport, top + offset < rows.count { selected = top + offset }
        case .enter:
            act(with: signal)
        case .ctrlL:
            Terminal.clearScreen()
        case .ctrlC:
            return .quit

        // ── Filter box ──
        case .char("/") where !searching:
            searching = true
        case .escape:
            if searching {
                searching = false
            } else if !filter.isEmpty {
                filter = ""
                applyFilter()
            } else {
                return .quit
            }
        case .backspace:
            if searching, !filter.isEmpty {
                filter.removeLast()
                applyFilter()
            } else {
                searching = false
            }

        // ── List-mode keys, ignored while typing so the letters stay letters ──
        case .char("j") where !searching:
            move(by: 1)
        case .char("k") where !searching:
            move(by: -1)
        case .char("g") where !searching:
            selected = 0
        case .char("G") where !searching:
            selected = max(0, rows.count - 1)
        case .char("q") where !searching, .char("Q") where !searching:
            return .quit
        case .char("a") where !searching:
            includePortless.toggle()
            refresh()
        case .char("s") where !searching:
            sort = sort.next
            rebuildCandidates()
            applyFilter()
        case .char("r") where !searching:
            refresh()
            note("refreshed")
        case .char("y") where !searching:
            copyPid()
        case .char("?") where !searching:
            Terminal.showHelp(HelpText.groups, theme: theme)
        case .char("m") where !searching:
            user = user == nil ? getuid() : nil
            refresh()

        // ── Acting. `x`/`X` rather than `k`/`K`: `k` is "up" in every list with
        //    vim keys in it, and a tool that kills on the up-arrow's twin is a
        //    tool that will one day kill the wrong thing. ──
        case .char("x") where !searching:
            act(with: signal)
        case .char("X") where !searching:
            act(with: .kill)

        // ── Typing into the box ──
        case .char(let c) where searching:
            filter.append(c)
            applyFilter()

        default:
            break
        }
        return .stay
    }

    // MARK: - Data

    /// Re-scan, keeping the cursor on the same process if it is still there.
    ///
    /// By pid, not by index: between two scans a process above the cursor can
    /// exit and every row below it shifts up one. Following the index would
    /// move the selection onto a neighbour silently, which in this program
    /// means the next keystroke signals something the user never chose.
    private mutating func refresh() {
        let keep = rows.indices.contains(selected) ? rows[selected].record.pid : nil
        let result = ProcessScanner.scan(
            .init(includePortless: includePortless, user: user)
        )
        all = initialQuery.filter(result.processes)
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
    private mutating func rebuildCandidates() {
        let now = Date()
        widths = TableLayout.widths(for: all, totalWidth: contentWidth, now: now)
        candidates = all.sorted(by: sort).map { record in
            (record, TableLayout.plainRow(cells: TableLayout.cells(for: record, now: now),
                                          widths: widths))
        }
    }

    private mutating func applyFilter() {
        rows = FuzzyMatch.filterAndSort(candidates, query: filter, label: \.label)
            .map { Row(record: $0.item.record, label: $0.item.label, indices: $0.indices) }
        // A filter that just got narrower can leave the cursor past the end;
        // clamping happens in the loop, but the top must not be left stranded
        // below it or the first frame after a keystroke scrolls for no reason.
        if selected >= rows.count { selected = max(0, rows.count - 1) }
        if top > selected { top = selected }
    }

    private mutating func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selected = max(0, min(rows.count - 1, selected + delta))
    }

    private mutating func clampSelection(viewport: Int) {
        selected = max(0, min(selected, max(0, rows.count - 1)))
        if selected < top { top = selected }
        if selected >= top + viewport { top = selected - viewport + 1 }
        top = max(0, min(top, max(0, rows.count - viewport)))
    }

    private mutating func note(_ text: String) {
        message = (text, Date().addingTimeInterval(3))
    }

    // MARK: - Acting

    /// Confirm, signal, then say what happened.
    ///
    /// The confirmation is not optional here even though `--yes` exists for the
    /// command line: on the command line the user typed the target and can read
    /// it back before pressing return, and in the picker the target is wherever
    /// a cursor happens to be sitting.
    private mutating func act(with signal: Signal) {
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

    private mutating func copyPid() {
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
    private func chrome(for size: Terminal.Size) -> Chrome {
        Chrome(size: size, width: forcedWidth ?? size.cols)
    }

    private func listRows(for size: Terminal.Size) -> Int {
        let chrome = chrome(for: size)
        return max(1, size.rows - chrome.headerLines - chrome.footerLines)
    }

    // Accessors the draw extension reads. Kept `internal` rather than making
    // the state itself internal, so the loop stays the only thing that writes.
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
