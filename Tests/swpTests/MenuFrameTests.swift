import XCTest
import swpCore
@testable import swp

/// Whole-frame assertions, driven off a fixed set of processes rather than the
/// machine's real table — which would make every one of these a coin toss.
final class MenuFrameTests: XCTestCase {

    private let sample: [ProcessRecord] = [
        ProcessRecord(pid: 100, name: "bun", path: "/bin/bun",
                      arguments: ["bun", "--hot", "serve.ts"], uid: 501, user: "dsaad",
                      memoryBytes: 1024 * 1024,
                      listeners: [Listener(port: 3000, netProtocol: .tcp, family: .v4, address: "*")]),
        ProcessRecord(pid: 200, name: "postgres", path: "/bin/postgres",
                      arguments: ["postgres", "-D", "/data"], uid: 501, user: "dsaad",
                      memoryBytes: 8 * 1024 * 1024,
                      listeners: [Listener(port: 5432, netProtocol: .tcp, family: .v4,
                                           address: "127.0.0.1")]),
    ]

    private func menu(width: Int = 100, query: Query = Query()) -> ProcessMenu {
        var menu = ProcessMenu(theme: .mono, signal: .term, sort: .port, includePortless: false,
                               user: nil, initialQuery: query, forcedWidth: width)
        menu.loadForTesting(sample)
        return menu
    }

    override func setUp() {
        super.setUp()
        Ansi.colorEnabled = false
    }

    fileprivate func plain(_ menu: ProcessMenu, rows: Int, cols: Int = 100) -> [String] {
        let size = Terminal.Size(rows: rows, cols: cols)
        let chrome = ProcessMenu.Chrome(size: size, width: cols)
        let viewport = max(1, rows - chrome.headerLines - chrome.footerLines)
        return menu.frame(size: size, viewport: viewport)
    }

    /// The frame must be exactly as tall as the screen: one row short leaves a
    /// stale line from the previous frame at the bottom, one row long scrolls
    /// the whole thing and desyncs every later redraw.
    func testFrameFillsTheScreenExactly() {
        for rows in [14, 20, 24, 40] {
            XCTAssertEqual(plain(menu(), rows: rows).count, rows, "at \(rows) rows")
        }
    }

    /// …and no line may be wider than the screen, or autowrap-off clipping eats
    /// the border.
    func testNoLineIsWiderThanTheFrame() {
        for cols in [50, 80, 100, 160] {
            for line in plain(menu(width: cols), rows: 24, cols: cols) {
                XCTAssertLessThanOrEqual(Ansi.displayWidth(line), cols, "at \(cols) columns")
            }
        }
    }

    func testTallTerminalsGetTheWordmark() {
        let lines = plain(menu(), rows: 30)
        XCTAssertTrue(lines.contains { $0.contains("╭─╴") }, "expected the wordmark")
        XCTAssertTrue(lines.contains { $0.contains("2 listening") })
    }

    /// A short terminal trades the wordmark for rows — eleven lines of masthead
    /// on a 16-row window would leave three rows of list.
    func testShortTerminalsGetTheCompactHeader() {
        let lines = plain(menu(), rows: 16)
        XCTAssertFalse(lines.contains { $0.contains("╭─╴") })
        XCTAssertTrue(lines.contains { $0.contains("swp") })
    }

    func testRowsShowTheProcesses() {
        let lines = plain(menu(), rows: 24)
        XCTAssertTrue(lines.contains { $0.contains("3000") && $0.contains("bun") })
        XCTAssertTrue(lines.contains { $0.contains("5432") && $0.contains("postgres") })
    }

    func testFilteringNarrowsAndSaysSo() {
        var menu = menu()
        menu.filterForTesting("postgres")
        let lines = plain(menu, rows: 30)
        XCTAssertTrue(lines.contains { $0.contains("1 of 2 listening") })
        XCTAssertFalse(lines.contains { $0.contains("bun ") })
    }

    /// An empty list explains itself rather than showing nothing at all.
    func testAnEmptyFilterResultExplainsItself() {
        var menu = menu()
        menu.filterForTesting("zzzzz")
        let lines = plain(menu, rows: 24)
        XCTAssertTrue(lines.contains { $0.contains("no process matches") })
    }

    /// The command-line query is applied before the picker opens.
    func testTheInitialQueryIsApplied() {
        let filtered = menu(query: Query(ports: [5432]))
        let lines = plain(filtered, rows: 24)
        XCTAssertTrue(lines.contains { $0.contains("postgres") })
        XCTAssertFalse(lines.contains { $0.contains("3000") })
    }

    /// The footer names the keys that act, so the destructive ones are never a
    /// thing you have to already know.
    func testTheFooterNamesTheActingKeys() {
        let footer = plain(menu(), rows: 24).dropLast().last ?? ""
        XCTAssertTrue(footer.contains("SIGTERM"))
        XCTAssertTrue(footer.contains("SIGKILL"))
        XCTAssertTrue(footer.contains("q quit"))
    }
}

extension MenuFrameTests {

    /// An empty list explains itself in the terms of whatever emptied it. After
    /// a kill clears the last match, "nothing of yours is listening — try sudo"
    /// is both wrong and alarming; the query is the reason.
    func testAnEmptyQueryResultNamesTheQuery() {
        var empty = ProcessMenu(theme: .mono, signal: .term, sort: .port, includePortless: false,
                                user: nil, initialQuery: Query(ports: [49999]), forcedWidth: 100)
        empty.loadForTesting([])
        let lines = plain(empty, rows: 24)
        XCTAssertTrue(lines.contains { $0.contains("nothing matches port 49999") },
                      "expected the query in the empty message")
        XCTAssertFalse(lines.contains { $0.contains("sudo") })
    }

    func testQueryDescriptionReadsLikeItWasTyped() {
        var menu = ProcessMenu(theme: .mono, signal: .term, sort: .port, includePortless: true,
                               user: nil,
                               initialQuery: Query(ports: [3000], pids: [42], terms: ["node"]),
                               forcedWidth: 100)
        menu.loadForTesting([])
        XCTAssertEqual(menu.queryDescription, "port 3000 and pid 42 and \"node\"")
    }
}

extension MenuFrameTests {

    /// Sorting and row rendering moved out of the keystroke path, so the two
    /// things that used to be rebuilt per letter now happen per scan. This
    /// pins the behaviour that move could break: the rows must still be in
    /// sort order, and still carry the filter's match offsets.
    func testFilteringPreservesOrderAndMatchOffsets() {
        var menu = menu()
        menu.filterForTesting("post")
        let rows = menu.visibleRows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].record.name, "postgres")
        XCTAssertFalse(rows[0].indices.isEmpty, "a filtered row carries its match offsets")
        // Every offset must be inside the row it will be painted on, or the
        // highlight lands on a different column than the one that matched.
        for index in rows[0].indices {
            XCTAssertLessThan(index, rows[0].label.count)
        }

        // Clearing the filter restores every row, in sort order.
        menu.filterForTesting("")
        XCTAssertEqual(menu.visibleRows.map(\.record.pid), [100, 200])
    }

    /// The rows are rendered to a width now, not per keystroke, so a row's text
    /// must still match the columns the header advertises.
    func testRenderedRowsMatchTheHeaderWidth() {
        let menu = menu(width: 100)
        let header = TableLayout.plainHeader(widths: menu.columnWidths)
        for row in menu.visibleRows {
            XCTAssertEqual(Ansi.displayWidth(row.label), Ansi.displayWidth(header))
        }
    }
}
