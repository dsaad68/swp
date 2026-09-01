import XCTest
import swpCore
@testable import swp

final class CommandLineOptionsTests: XCTestCase {

    private func parse(_ arguments: String...) -> Options {
        guard case .success(let options) = Options.parse(arguments) else {
            XCTFail("expected \(arguments) to parse")
            return Options()
        }
        return options
    }

    private func failure(_ arguments: String...) -> String? {
        guard case .failure(let message, _) = Options.parse(arguments) else { return nil }
        return message
    }

    func testDefaultsToThePicker() {
        let options = parse()
        XCTAssertEqual(options.mode, .pick)
        XCTAssertTrue(options.query.isEmpty)
        XCTAssertFalse(options.includePortless)
        XCTAssertEqual(options.signal, .term)
        XCTAssertEqual(options.sort, .port)
    }

    func testBareWordsBecomeAQuery() {
        XCTAssertEqual(parse("3000").query, Query(ports: [3000]))
        XCTAssertEqual(parse("node").query, Query(terms: ["node"]))
        // Several words narrow, and each keeps its own kind.
        XCTAssertEqual(parse("node", "3000").query, Query(ports: [3000], terms: ["node"]))
    }

    func testExplicitQueryFlags() {
        let options = parse("-p", "8080", "--port", "3000", "-n", "bun", "--pid", "42")
        XCTAssertEqual(options.query.ports, [8080, 3000])
        XCTAssertEqual(options.query.terms, ["bun"])
        XCTAssertEqual(options.query.pids, [42])
    }

    func testModes() {
        XCTAssertEqual(parse("-l").mode, .list)
        XCTAssertEqual(parse("--kill", "3000").mode, .kill)
        // JSON is only ever a listing.
        XCTAssertEqual(parse("--json").mode, .list)
        XCTAssertTrue(parse("--json").json)
    }

    /// `--json` must not quietly turn a kill into a listing.
    func testJsonDoesNotOverrideAnExplicitMode() {
        let options = parse("-k", "--json", "3000")
        XCTAssertEqual(options.mode, .kill)
    }

    func testTwoModesIsAnError() {
        XCTAssertEqual(failure("-l", "-k"), "swp: -k cannot be combined with -l")
        // The same one twice is not a mistake worth stopping for.
        XCTAssertNil(failure("-l", "--list"))
    }

    func testSignals() {
        XCTAssertEqual(parse("-9").signal, .kill)
        XCTAssertEqual(parse("--signal", "HUP").signal, .hangup)
        XCTAssertEqual(parse("-s", "9").signal, .kill)
        XCTAssertNotNil(failure("--signal", "BANANA"))
        XCTAssertNotNil(failure("--signal"))
    }

    /// A flag must not swallow the next flag as its value — `--signal --json`
    /// used to try to send SIG`--json`.
    func testAValueIsNotTheNextFlag() {
        XCTAssertNotNil(failure("--signal", "--json"))
        XCTAssertNotNil(failure("--name", "--json"))
        // A negative-looking *number* is still a value, so `--pid -1` is a pid.
        XCTAssertEqual(parse("--pid", "-1").query.pids, [-1])
    }

    func testUserAndMe() {
        XCTAssertEqual(parse("--me").user, getuid())
        XCTAssertEqual(parse("-u", String(getuid())).user, getuid())
        XCTAssertNotNil(failure("-u", "definitely-not-a-user-name"))
    }

    func testSortAndPresentation() {
        XCTAssertEqual(parse("--sort", "memory").sort, .memory)
        XCTAssertEqual(parse("--sort", "MEMORY").sort, .memory)
        XCTAssertNotNil(failure("--sort", "sideways"))
        XCTAssertEqual(parse("--width", "100").width, 100)
        XCTAssertNotNil(failure("--width", "0"))
        XCTAssertEqual(parse("--theme", "light").themeName, "light")
        XCTAssertTrue(parse("--no-color").noColor)
    }

    /// A typo in a flag must not be silently treated as a search term: `swp
    /// --kil node` would otherwise list node and look like a kill that failed.
    func testUnknownFlagsAreRejected() {
        XCTAssertEqual(failure("--kil", "node"), "swp: unknown option --kil\nTry 'swp --help'.")
    }

    func testHelpAndVersion() {
        XCTAssertTrue(parse("--help").showHelp)
        XCTAssertTrue(parse("-V").showVersion)
    }

    /// The help text is the tool's only documentation at the terminal, so it
    /// has to name every mode it can be put into.
    func testUsageMentionsEveryMode() {
        for fragment in ["--list", "--kill", "--signal", "--json", "--all", "sudo swp"] {
            XCTAssertTrue(Options.usage.contains(fragment), "usage should mention \(fragment)")
        }
    }
}

extension CommandLineOptionsTests {

    /// The ports-only default keeps the *browse* short; it must not narrow a
    /// search. `swp -k --pid 4123` used to fail outright because the process it
    /// named held no port.
    func testANamedTargetSearchesEveryProcess() {
        XCTAssertTrue(parse("--pid", "4123").includePortless)
        XCTAssertTrue(parse("chrome").includePortless)
        XCTAssertTrue(parse("-n", "chrome").includePortless)
        // A bare browse, and a port query, stay listener-only.
        XCTAssertFalse(parse().includePortless)
        XCTAssertFalse(parse("3000").includePortless)
        XCTAssertFalse(parse("-p", "3000").includePortless)
    }
}
