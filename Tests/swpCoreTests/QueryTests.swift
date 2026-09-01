import XCTest
@testable import swpCore

/// A process built for a test: nothing here touches the machine's real table,
/// which would make every assertion depend on what happens to be running.
func makeProcess(pid: Int32 = 100, name: String = "node", path: String = "/usr/bin/node",
                 arguments: [String] = [], user: String = "dsaad", uid: uid_t = 501,
                 memory: UInt64? = 1024 * 1024, started: Date? = nil,
                 ports: [UInt16] = []) -> ProcessRecord {
    ProcessRecord(
        pid: pid, ppid: 1, name: name, path: path,
        arguments: arguments.isEmpty ? [name] : arguments,
        uid: uid, user: user, startTime: started, memoryBytes: memory,
        listeners: ports.map { Listener(port: $0, netProtocol: .tcp, family: .v4, address: "*") }
    )
}

final class QueryTests: XCTestCase {

    func testBareNumberIsAPort() {
        XCTAssertEqual(Query.classify("3000"), Query(ports: [3000]))
    }

    /// Above the port range a number can only be a pid, so `swp 41235` needs no
    /// flag to mean the obvious thing.
    func testNumberTooLargeForAPortIsAPid() {
        XCTAssertEqual(Query.classify("70000"), Query(pids: [70000]))
    }

    func testAnythingElseIsAText() {
        XCTAssertEqual(Query.classify("node"), Query(terms: ["node"]))
        XCTAssertEqual(Query.classify("-3"), Query(terms: ["-3"]))
    }

    func testPortsMatchAnyOfTheListeners() {
        let record = makeProcess(ports: [3000, 8080])
        XCTAssertTrue(Query(ports: [8080]).matches(record))
        XCTAssertFalse(Query(ports: [9090]).matches(record))
    }

    /// Across kinds the query is an AND, so each extra word narrows.
    func testKindsCombineWithAnd() {
        let record = makeProcess(name: "node", ports: [3000])
        XCTAssertTrue(Query(ports: [3000], terms: ["node"]).matches(record))
        XCTAssertFalse(Query(ports: [3000], terms: ["bun"]).matches(record))
    }

    func testTextMatchesNameCommandOrUser() {
        let record = makeProcess(name: "node", arguments: ["node", "server.js"], user: "dsaad")
        XCTAssertTrue(Query(terms: ["serv"]).matches(record))
        XCTAssertTrue(Query(terms: ["dsaad"]).matches(record))
        XCTAssertTrue(Query(terms: ["NODE"]).matches(record))   // case-insensitive
        XCTAssertFalse(Query(terms: ["python"]).matches(record))
    }

    /// The rule that keeps `swp node --kill` from reaching six VS Code helpers
    /// whose *arguments* mention node.
    func testNameMatchesDropCommandOnlyMatches() {
        let real = makeProcess(pid: 1, name: "node", arguments: ["node", "server.js"])
        let helper = makeProcess(pid: 2, name: "Code Helper",
                                 arguments: ["Code Helper", "--utility-sub-type=node.mojom"])
        let filtered = Query(terms: ["node"]).filter([helper, real])
        XCTAssertEqual(filtered.map(\.pid), [1])
    }

    /// …and the looser reading is still there when nothing matches by name.
    func testCommandMatchesSurviveWhenNoNameMatches() {
        let helper = makeProcess(pid: 2, name: "Code Helper",
                                 arguments: ["Code Helper", "--utility-sub-type=node.mojom"])
        XCTAssertEqual(Query(terms: ["mojom"]).filter([helper]).map(\.pid), [2])
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(Query().isEmpty)
        XCTAssertEqual(Query().filter([makeProcess(), makeProcess(pid: 2)]).count, 2)
    }
}
