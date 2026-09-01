import XCTest
@testable import swpCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Socket calls that are spelled differently on the two platforms.
///
/// `SOCK_STREAM` is an `Int32` in Darwin's headers and a `__socket_type` in
/// Glibc's, and bare `bind` resolves to `XCTestCase.bind` inside a test case, so
/// it has to be qualified — with a module name that differs by platform. Both
/// only show up when the Linux job runs, which is exactly the kind of thing a
/// macOS-only developer never sees.
private enum Sockets {

    static func stream() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_INET, SOCK_STREAM, 0)
        #else
        return socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    static func bind(_ fd: Int32, _ addr: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(fd, addr, length)
        #else
        return Glibc.bind(fd, addr, length)
        #endif
    }
}

/// The scanner is the one part that cannot be tested against fixtures — it is
/// the seam onto the running machine. So these tests assert about the one
/// process whose truth is known here: this one.
final class ScannerTests: XCTestCase {

    func testScanFindsThisProcess() {
        let result = ProcessScanner.scan(.init(includePortless: true, excludeSelf: false))
        guard let me = result.processes.first(where: { $0.pid == getpid() }) else {
            return XCTFail("the scan did not include the running test process")
        }
        XCTAssertFalse(me.name.isEmpty)
        XCTAssertTrue(me.isOwnedByCurrentUser)
        XCTAssertEqual(me.uid, getuid())
        XCTAssertGreaterThan(me.memoryBytes ?? 0, 0)
        XCTAssertNotNil(me.startTime)
        XCTAssertFalse(me.arguments.isEmpty, "the argument vector of our own process is readable")
    }

    func testExcludeSelfIsTheDefault() {
        let result = ProcessScanner.scan(.init(includePortless: true))
        XCTAssertFalse(result.processes.contains { $0.pid == getpid() })
    }

    /// The whole point of the tool, end to end: open a listening socket, and
    /// find it by its port.
    func testAListeningSocketIsFoundByPort() throws {
        let (fd, port) = try openListener()
        defer { close(fd) }

        let result = ProcessScanner.scan(.init(excludeSelf: false))
        guard let me = result.processes.first(where: { $0.pid == getpid() }) else {
            return XCTFail("a process holding a port was filtered out of the ports view")
        }
        XCTAssertTrue(me.listeners.contains { $0.port == port && $0.netProtocol == .tcp },
                      "expected port \(port) among \(me.listeners.map(\.display))")
        XCTAssertTrue(Query(ports: [port]).matches(me))
    }

    /// Without a port, a process is not in the default view at all — which is
    /// what keeps the list to the two dozen rows worth reading.
    func testPortlessProcessesAreHiddenByDefault() {
        let ports = ProcessScanner.scan(.init())
        XCTAssertTrue(ports.processes.allSatisfy(\.hasPorts))
        let all = ProcessScanner.scan(.init(includePortless: true))
        XCTAssertGreaterThan(all.processes.count, ports.processes.count)
    }

    func testUserFilterKeepsOnlyThatUser() {
        let mine = ProcessScanner.scan(.init(includePortless: true, user: getuid()))
        XCTAssertTrue(mine.processes.allSatisfy { $0.uid == getuid() })
        XCTAssertFalse(mine.processes.isEmpty)
    }

    func testLookupByPid() {
        let me = ProcessScanner.process(pid: getpid())
        XCTAssertEqual(me?.pid, getpid())
        XCTAssertNil(ProcessScanner.process(pid: 999_999))
    }

    /// Bind a TCP socket on a port the kernel picks, so the test cannot collide
    /// with whatever the machine is already running.
    private func openListener() throws -> (fd: Int32, port: UInt16) {
        let fd = Sockets.stream()
        try XCTUnwrap(fd >= 0 ? true : nil, "socket() failed")
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                       // let the kernel choose
        addr.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Sockets.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTUnwrap(bound == 0 ? true : nil, "bind() failed")
        try XCTUnwrap(listen(fd, 4) == 0 ? true : nil, "listen() failed")

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return (fd, UInt16(bigEndian: actual.sin_port))
    }
}

final class ProcessSortTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private var sample: [ProcessRecord] {
        [
            makeProcess(pid: 30, name: "zed", memory: 100, started: now.addingTimeInterval(-10), ports: [9000]),
            makeProcess(pid: 10, name: "alpha", memory: 300, started: now.addingTimeInterval(-30)),
            makeProcess(pid: 20, name: "mid", memory: 200, started: now.addingTimeInterval(-20), ports: [80]),
        ]
    }

    func testSortByPortPutsPortlessLast() {
        XCTAssertEqual(sample.sorted(by: .port).map(\.pid), [20, 30, 10])
    }

    func testOtherOrders() {
        XCTAssertEqual(sample.sorted(by: .pid).map(\.pid), [10, 20, 30])
        XCTAssertEqual(sample.sorted(by: .name).map(\.pid), [10, 20, 30])
        XCTAssertEqual(sample.sorted(by: .memory).map(\.pid), [10, 20, 30])   // biggest first
        XCTAssertEqual(sample.sorted(by: .started).map(\.pid), [30, 20, 10])  // newest first
    }

    /// Equal rows must not swap places between refreshes: the cursor would move
    /// off the row the user is looking at, and the next keystroke acts on it.
    func testEqualRowsBreakTiesOnPid() {
        let tied = [makeProcess(pid: 9, memory: 1), makeProcess(pid: 3, memory: 1)]
        XCTAssertEqual(tied.sorted(by: .memory).map(\.pid), [3, 9])
        XCTAssertEqual(tied.sorted(by: .name).map(\.pid), [3, 9])
        XCTAssertEqual(tied.sorted(by: .port).map(\.pid), [3, 9])
    }

    func testSortCycleWraps() {
        var order = ProcessSort.port
        for _ in ProcessSort.allCases { order = order.next }
        XCTAssertEqual(order, .port)
    }
}
