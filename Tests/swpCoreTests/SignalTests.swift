import XCTest
@testable import swpCore

final class SignalTests: XCTestCase {

    func testParseAcceptsEverySpelling() {
        XCTAssertEqual(Signal.parse("TERM"), .term)
        XCTAssertEqual(Signal.parse("sigterm"), .term)
        XCTAssertEqual(Signal.parse("15"), .term)
        XCTAssertEqual(Signal.parse("9"), .kill)
        XCTAssertEqual(Signal.parse("KILL"), .kill)
    }

    func testParseRejectsNonsenseAndOutOfRangeNumbers() {
        XCTAssertNil(Signal.parse("BANANA"))
        XCTAssertNil(Signal.parse("0"))     // kill -0 signals nothing; never a request
        XCTAssertNil(Signal.parse("99"))
        XCTAssertNil(Signal.parse("--json"))
    }

    func testDisplayNameCarriesThePrefix() {
        XCTAssertEqual(Signal.term.displayName, "SIGTERM")
    }

    /// The guard that stands between a mistyped pid and a logout.
    func testInitAndNonPositivePidsAreRefused() {
        for pid: Int32 in [1, 0, -1] {
            let outcome = Killer.send(.term, to: pid)
            XCTAssertEqual(outcome.failure, .refusedInit, "pid \(pid) should be refused")
        }
    }

    func testSignallingAGoneProcessSaysSo() {
        // A pid that cannot plausibly be live: allocate one and let it exit.
        let outcome = Killer.send(.term, to: 999_999)
        XCTAssertEqual(outcome.failure, .noSuchProcess)
        XCTAssertFalse(outcome.succeeded)
    }

    func testIsAliveSeesOurselves() {
        XCTAssertTrue(Killer.isAlive(getpid()))
        XCTAssertFalse(Killer.isAlive(999_999))
    }

    /// The failure messages are what a user reads when nothing happened, so
    /// they say what to do rather than naming an errno.
    func testFailureMessagesAreActionable() {
        XCTAssertTrue(Killer.Failure.notPermitted.message.contains("sudo"))
        XCTAssertTrue(Killer.Failure.noSuchProcess.message.contains("exited"))
    }
}
