import XCTest
import swpCore
@testable import swp

final class ReportTests: XCTestCase {

    private let record = ProcessRecord(
        pid: 14322, ppid: 14320, name: "bun", path: "/opt/homebrew/bin/bun",
        arguments: ["bun", "--hot", "serve.ts"], uid: 501, user: "dsaad",
        startTime: Date(timeIntervalSince1970: 1_000_000), memoryBytes: 60 * 1024 * 1024,
        listeners: [Listener(port: 3000, netProtocol: .tcp, family: .v4, address: "*")]
    )

    override func setUp() {
        super.setUp()
        Ansi.colorEnabled = false
    }

    func testListingHasAHeaderAndARowPerProcess() {
        let lines = Report.lines(for: [record], theme: .mono, width: 100)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("PORT"))
        XCTAssertTrue(lines[1].contains("3000"))
        XCTAssertTrue(lines[1].contains("14322"))
        XCTAssertTrue(lines[1].contains("--hot serve.ts"))
    }

    /// Trailing padding is invisible on screen and real in a pipe.
    func testListingHasNoTrailingWhitespace() {
        for line in Report.lines(for: [record], theme: .mono, width: 200) {
            XCTAssertFalse(line.hasSuffix(" "), "trailing space in: '\(line)'")
        }
    }

    func testEmptyListingIsEmpty() {
        XCTAssertTrue(Report.lines(for: [], theme: .mono, width: 100).isEmpty)
    }

    func testJSONCarriesTheFieldsAScriptWouldWant() throws {
        let data = Data(Report.json(for: [record]).utf8)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0]["pid"] as? Int, 14322)
        XCTAssertEqual(parsed[0]["name"] as? String, "bun")
        XCTAssertEqual(parsed[0]["command"] as? String, "bun --hot serve.ts")
        XCTAssertEqual(parsed[0]["memory_bytes"] as? Int, 60 * 1024 * 1024)
        let listeners = try XCTUnwrap(parsed[0]["listeners"] as? [[String: Any]])
        XCTAssertEqual(listeners[0]["port"] as? Int, 3000)
        XCTAssertEqual(listeners[0]["protocol"] as? String, "tcp")
        XCTAssertEqual(listeners[0]["address"] as? String, "*")
    }

    /// Slashes unescaped: a path is the most common field in this output, and
    /// `\/\/` in every one of them is unreadable at a terminal.
    func testJSONDoesNotEscapeSlashes() {
        XCTAssertTrue(Report.json(for: [record]).contains("/opt/homebrew/bin/bun"))
    }

    func testEmptyJSONIsAnEmptyArray() {
        XCTAssertEqual(Report.json(for: []), "[]")
    }

    func testDescribeNamesTheProcessAndItsPort() {
        XCTAssertEqual(Report.describe(record), "bun (pid 14322) on 3000")
    }

    /// "Signalled" and "killed" are different claims, and the tool must never
    /// make the second one when it only did the first.
    func testOutcomeDistinguishesSignalledFromKilled() {
        let sent = Killer.Outcome(pid: 1, name: "bun", signal: .term, failure: nil)
        XCTAssertTrue(Report.outcomeLine(sent, exited: true, theme: .mono).hasPrefix("killed"))
        let survived = Report.outcomeLine(sent, exited: false, theme: .mono)
        XCTAssertTrue(survived.hasPrefix("signalled"))
        XCTAssertTrue(survived.contains("still running"))
    }

    func testOutcomeReportsFailuresWithTheirReason() {
        let denied = Killer.Outcome(pid: 1, name: "sshd", signal: .term, failure: .notPermitted)
        let line = Report.outcomeLine(denied, exited: false, theme: .mono)
        XCTAssertTrue(line.contains("could not signal"))
        XCTAssertTrue(line.contains("sudo"))
    }
}
