import XCTest
@testable import swpCore

final class CPUSamplerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func record(pid: Int32 = 1, cpu: TimeInterval?, started: Date?) -> ProcessRecord {
        ProcessRecord(pid: pid, name: "p", uid: 501, user: "u",
                      startTime: started, cpuSeconds: cpu)
    }

    /// A rate needs two readings. The first scan can only be a baseline, and
    /// must not invent a number from a cumulative counter.
    func testNoPercentageUntilTheSecondScan() {
        var sampler = CPUSampler()
        XCTAssertFalse(sampler.hasBaseline)
        var first = [record(cpu: 10, started: t0)]
        sampler.annotate(&first, now: t0)
        XCTAssertNil(first[0].cpuPercent)
        XCTAssertTrue(sampler.hasBaseline)
    }

    func testPercentageIsCPUTimeOverWallTime() {
        var sampler = CPUSampler()
        var first = [record(cpu: 10, started: t0)]
        sampler.annotate(&first, now: t0)

        // Half a second of CPU across one second of wall clock: 50% of a core.
        var second = [record(cpu: 10.5, started: t0)]
        sampler.annotate(&second, now: t0.addingTimeInterval(1))
        XCTAssertEqual(second[0].cpuPercent ?? 0, 50, accuracy: 0.001)
    }

    /// More than one core is a real answer, not an error to clamp away — it is
    /// how top and ps report a multithreaded process.
    func testPercentageCanExceedOneHundred() {
        var sampler = CPUSampler()
        var first = [record(cpu: 0, started: t0)]
        sampler.annotate(&first, now: t0)
        var second = [record(cpu: 3.5, started: t0)]
        sampler.annotate(&second, now: t0.addingTimeInterval(1))
        XCTAssertEqual(second[0].cpuPercent ?? 0, 350, accuracy: 0.001)
    }

    /// pids are reused. Subtracting a dead process's counter from the live one
    /// wearing its number reports a wild spike or a negative, so the start time
    /// is checked as an identity.
    func testAReusedPidIsNotTreatedAsTheSameProcess() {
        var sampler = CPUSampler()
        var first = [record(pid: 42, cpu: 900, started: t0)]
        sampler.annotate(&first, now: t0)

        let restarted = t0.addingTimeInterval(30)
        var second = [record(pid: 42, cpu: 0.1, started: restarted)]
        sampler.annotate(&second, now: t0.addingTimeInterval(60))
        XCTAssertNil(second[0].cpuPercent, "a different process reusing the pid gets no rate")
    }

    /// Two scans in the same instant would divide by nothing.
    func testAZeroIntervalProducesNothingRatherThanInfinity() {
        var sampler = CPUSampler()
        var first = [record(cpu: 1, started: t0)]
        sampler.annotate(&first, now: t0)
        var second = [record(cpu: 2, started: t0)]
        sampler.annotate(&second, now: t0)
        XCTAssertNil(second[0].cpuPercent)
    }

    /// A process the kernel refused gets no rate rather than a zero — an
    /// unknown is not an idle.
    func testAnUnreadableCounterProducesNothing() {
        var sampler = CPUSampler()
        var first = [record(cpu: nil, started: t0)]
        sampler.annotate(&first, now: t0)
        var second = [record(cpu: nil, started: t0)]
        sampler.annotate(&second, now: t0.addingTimeInterval(1))
        XCTAssertNil(second[0].cpuPercent)
    }

    /// A process seen for the first time on the second scan has no baseline of
    /// its own, however many other processes do.
    func testANewProcessGetsNoRateOnItsFirstAppearance() {
        var sampler = CPUSampler()
        var first = [record(pid: 1, cpu: 1, started: t0)]
        sampler.annotate(&first, now: t0)
        var second = [record(pid: 1, cpu: 2, started: t0), record(pid: 2, cpu: 5, started: t0)]
        sampler.annotate(&second, now: t0.addingTimeInterval(1))
        XCTAssertNotNil(second[0].cpuPercent)
        XCTAssertNil(second[1].cpuPercent)
    }

    func testResetDropsTheBaseline() {
        var sampler = CPUSampler()
        var first = [record(cpu: 1, started: t0)]
        sampler.annotate(&first, now: t0)
        sampler.reset()
        XCTAssertFalse(sampler.hasBaseline)
    }
}

final class CPUSortTests: XCTestCase {

    private func record(pid: Int32, cpu: Double?) -> ProcessRecord {
        ProcessRecord(pid: pid, name: "p", uid: 501, user: "u", cpuPercent: cpu)
    }

    /// Busiest first, and an unknown sorts to the bottom: a process whose CPU
    /// we were refused is not the answer to "what is eating my CPU", and
    /// treating nil as zero would put it above a genuinely idle one for no
    /// reason anyone could see.
    func testBusiestFirstAndUnknownsLast() {
        let sorted = [record(pid: 1, cpu: nil), record(pid: 2, cpu: 0),
                      record(pid: 3, cpu: 40)].sorted(by: .cpu)
        XCTAssertEqual(sorted.map(\.pid), [3, 2, 1])
    }
}
