import XCTest
import swpCore
@testable import swp

private func makeProcess(pid: Int32 = 100, name: String = "node", path: String = "/usr/bin/node",
                         arguments: [String] = [], memory: UInt64? = 1024 * 1024,
                         ports: [UInt16] = [], addresses: [String] = []) -> ProcessRecord {
    ProcessRecord(
        pid: pid, ppid: 1, name: name, path: path,
        arguments: arguments, uid: 501, user: "dsaad",
        startTime: nil, memoryBytes: memory,
        listeners: ports.enumerated().map { index, port in
            Listener(port: port, netProtocol: .tcp, family: .v4,
                     address: index < addresses.count ? addresses[index] : "*")
        }
    )
}

final class TableLayoutTests: XCTestCase {

    /// The default column set — CPU absent, as it is for any caller that has
    /// not measured a rate.
    private let columns = TableLayout.columns(showCPU: false)

    override func setUp() {
        super.setUp()
        Ansi.colorEnabled = false
    }

    // MARK: - The command column

    /// argv[0] only repeats the NAME column beside it, so it is dropped.
    func testCommandDropsARedundantArgv0() {
        let record = makeProcess(name: "bun", arguments: ["bun", "--hot", "serve.ts"])
        XCTAssertEqual(TableLayout.command(for: record), "--hot serve.ts")
    }

    /// …but kept when it says something the name does not. A process that
    /// rewrote its argv is telling you what it thinks it is, and "Raycast
    /// Backend" against the name `node` is the whole answer.
    func testCommandKeepsAnInformativeArgv0() {
        let record = makeProcess(name: "node", arguments: ["Raycast Backend"])
        XCTAssertEqual(TableLayout.command(for: record), "Raycast Backend")
    }

    /// An argv rewritten in place is NUL-padded; joining those unfiltered
    /// produced a cell of nothing but spaces.
    func testCommandIgnoresEmptyArguments() {
        let record = makeProcess(name: "node", arguments: ["Raycast Backend", "", ""])
        XCTAssertEqual(TableLayout.command(for: record), "Raycast Backend")
    }

    func testCommandFallsBackToThePathAndThenTheName() {
        XCTAssertEqual(TableLayout.command(for: makeProcess(name: "node", arguments: ["node"])),
                       "/usr/bin/node")
        XCTAssertEqual(TableLayout.command(for: makeProcess(name: "sshd", path: "", arguments: [])),
                       "[sshd]")
    }

    // MARK: - Widths

    /// One outlier must not set the width for everybody: a browser helper
    /// holding twenty ports used to push the command line off the screen.
    func testColumnsAreCappedAgainstOutliers() {
        let outlier = makeProcess(name: String(repeating: "x", count: 80),
                                  ports: Array(1000...1020).map(UInt16.init))
        let widths = TableLayout.widths(for: [outlier], columns: columns, totalWidth: 200)
        XCTAssertLessThanOrEqual(widths[0], 14)     // PORT
        XCTAssertLessThanOrEqual(widths[5], 26)     // NAME
    }

    /// A row must never be wider than the frame that holds it, at any width.
    func testRowsFitTheWidthTheyWereSizedFor() {
        let records = [
            makeProcess(name: "Code - Insiders Helper (Plugin)",
                        arguments: ["x", String(repeating: "--flag ", count: 40)], ports: [40509]),
            makeProcess(pid: 2, name: "bun", arguments: ["bun", "--hot", "serve.ts"], ports: [3000]),
        ]
        for width in [44, 60, 80, 120, 200] {
            let widths = TableLayout.widths(for: records, columns: columns, totalWidth: width)
            for record in records {
                let row = TableLayout.plainRow(cells: TableLayout.cells(for: record, columns: columns), widths: widths, columns: columns)
                XCTAssertEqual(Ansi.displayWidth(row), width,
                               "row should fill exactly \(width) columns")
            }
            XCTAssertEqual(Ansi.displayWidth(TableLayout.plainHeader(widths: widths, columns: columns)),
                           width)
        }
    }

    /// Below about 44 columns even the floors do not fit; the layout stops
    /// shrinking there and the frame clips what is left, which is the only
    /// remaining answer on a terminal that narrow.
    func testBelowTheFloorTheLayoutStopsShrinking() {
        let record = makeProcess(ports: [3000])
        let narrow = TableLayout.widths(for: [record], columns: columns, totalWidth: 20)
        let row = TableLayout.plainRow(cells: TableLayout.cells(for: record, columns: columns),
                                       widths: narrow, columns: columns)
        // The floors themselves are wider than the frame, so the row overflows…
        XCTAssertGreaterThan(Ansi.displayWidth(row), 20)
        // …and the frame is what cuts it, exactly as it does for a long command.
        XCTAssertEqual(Ansi.displayWidth(Format.truncate(row, to: 20)), 20)
    }

    func testNumericColumnsAreRightAligned() {
        let widths = TableLayout.widths(for: [makeProcess(pid: 7)], columns: columns, totalWidth: 100)
        let row = TableLayout.plainRow(cells: TableLayout.cells(for: makeProcess(pid: 7),
                                                                columns: columns),
                                       widths: widths, columns: columns)
        let starts = TableLayout.columnStarts(widths)
        let pidCell = Array(row)[starts[1]..<(starts[1] + widths[1])]
        XCTAssertTrue(String(pidCell).hasSuffix("7"))
        XCTAssertTrue(String(pidCell).hasPrefix(" "))
    }

    // MARK: - Styling

    /// With colour off the styled row is byte-for-byte the plain one, which is
    /// what makes a redirected listing safe to pipe into anything.
    func testStylingIsAbsentWhenColourIsOff() {
        Ansi.colorEnabled = false
        let record = makeProcess(ports: [3000])
        let widths = TableLayout.widths(for: [record], columns: columns, totalWidth: 80)
        let plain = TableLayout.plainRow(cells: TableLayout.cells(for: record, columns: columns), widths: widths, columns: columns)
        XCTAssertEqual(TableLayout.styledRow(plain, widths: widths, columns: columns, record: record, theme: .dark),
                       plain)
    }

    /// The styled row must carry the same visible text as the plain one — the
    /// escapes are the only difference, however many runs it took.
    func testStylingPreservesTheVisibleText() {
        Ansi.colorEnabled = true
        defer { Ansi.colorEnabled = false }
        let record = makeProcess(ports: [3000], addresses: ["127.0.0.1"])
        let widths = TableLayout.widths(for: [record], columns: columns, totalWidth: 80)
        let plain = TableLayout.plainRow(cells: TableLayout.cells(for: record, columns: columns), widths: widths, columns: columns)
        let styled = TableLayout.styledRow(plain, widths: widths, columns: columns,
                                           record: record, theme: .dark, highlight: [0, 1, 20])
        XCTAssertEqual(Ansi.displayWidth(styled), Ansi.displayWidth(plain))
        // Stripped of its escapes the styled row is the plain row — a highlight
        // splits "3000" across runs, so a substring check would not show that.
        let stripped = styled.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "",
                                                   options: .regularExpression)
        XCTAssertEqual(stripped, plain)
    }

    /// Runs, not one escape per character: the per-character version cost 40 KB
    /// a frame, more than a pty hands over in one piece.
    func testStylingEmitsRunsRatherThanPerCharacterEscapes() {
        Ansi.colorEnabled = true
        defer { Ansi.colorEnabled = false }
        let record = makeProcess(ports: [3000])
        let widths = TableLayout.widths(for: [record], columns: columns, totalWidth: 120)
        let plain = TableLayout.plainRow(cells: TableLayout.cells(for: record, columns: columns), widths: widths, columns: columns)
        let styled = TableLayout.styledRow(plain, widths: widths, columns: columns, record: record, theme: .dark)
        let escapes = styled.components(separatedBy: "\u{1B}[").count - 1
        XCTAssertLessThanOrEqual(escapes, columns.count + 1)
    }
}

extension TableLayoutTests {

    /// The CPU column appears only when the caller measured a rate. A column of
    /// dashes tells the reader nothing and costs the command line six columns.
    func testCPUColumnIsOptional() {
        XCTAssertFalse(TableLayout.columns(showCPU: false).contains(.cpu))
        XCTAssertTrue(TableLayout.columns(showCPU: true).contains(.cpu))
        XCTAssertEqual(TableLayout.columns(showCPU: true).count,
                       TableLayout.columns(showCPU: false).count + 1)
    }

    /// Adding a column must not break the invariant every other layout test
    /// rests on: a row still fills exactly the width it was sized for.
    func testRowsWithCPUStillFitTheirWidth() {
        let withCPU = TableLayout.columns(showCPU: true)
        let record = ProcessRecord(pid: 1, name: "bun", path: "/bin/bun",
                                   arguments: ["bun", "--hot", "serve.ts"], uid: 501, user: "dsaad",
                                   memoryBytes: 1024 * 1024, cpuPercent: 137.4)
        for width in [50, 80, 120] {
            let widths = TableLayout.widths(for: [record], columns: withCPU, totalWidth: width)
            let row = TableLayout.plainRow(cells: TableLayout.cells(for: record, columns: withCPU),
                                           widths: widths, columns: withCPU)
            XCTAssertEqual(Ansi.displayWidth(row), width, "at \(width) columns")
            XCTAssertTrue(row.contains("137%"))
        }
    }
}
