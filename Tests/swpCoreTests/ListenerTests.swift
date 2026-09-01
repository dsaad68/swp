import XCTest
@testable import swpCore

final class ListenerTests: XCTestCase {

    private func listener(_ port: UInt16, _ address: String = "*",
                          _ family: Listener.Family = .v4,
                          _ netProtocol: Listener.NetProtocol = .tcp) -> Listener {
        Listener(port: port, netProtocol: netProtocol, family: family, address: address)
    }

    /// A dual-stack server reports the same endpoint twice; two identical rows
    /// side by side are noise, and v4 is the spelling people typed.
    func testMergeCollapsesDualStackDuplicates() {
        let merged = [listener(3000, "*", .v6), listener(3000, "*", .v4)].merged()
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.family, .v4)
    }

    func testMergeKeepsDifferentAddressesAndProtocols() {
        let merged = [
            listener(3000, "127.0.0.1"),
            listener(3000, "*"),
            listener(3000, "*", .v4, .udp),
        ].merged()
        XCTAssertEqual(merged.count, 3)
    }

    /// Stable order across refreshes: a list that reshuffles under the cursor
    /// is a list you cannot safely kill from.
    func testMergeSortsByPort() {
        let merged = [listener(9000), listener(80), listener(3000)].merged()
        XCTAssertEqual(merged.map(\.port), [80, 3000, 9000])
    }

    func testPortSummaryDeduplicatesAndTruncates() {
        let many = [listener(3000, "*"), listener(3000, "127.0.0.1"), listener(8080), listener(9090)]
        XCTAssertEqual(many.portSummary(limit: 3), "3000,8080,9090")
        XCTAssertEqual(many.portSummary(limit: 2), "3000,8080+1")
    }

    func testWildcardIsFlagged() {
        XCTAssertTrue(listener(3000, "*").isWildcard)
        XCTAssertFalse(listener(3000, "127.0.0.1").isWildcard)
        XCTAssertEqual(listener(3000, "127.0.0.1").display, "127.0.0.1:3000")
    }
}
