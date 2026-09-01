import Foundation

/// Turns the cumulative CPU counters two scans apart into a percentage.
///
/// Neither platform publishes an instantaneous CPU figure worth having —
/// macOS's `kinfo_proc.p_pctcpu` is hard zero on anything modern, and Linux's
/// only rate is the load average, which is not per process. What both do
/// publish is total CPU time consumed since the process started, so a rate has
/// to be measured: take that counter twice, divide the difference by the wall
/// time between the readings.
///
/// This is what `top` does, and it is why `top` has a refresh interval at all.
/// The alternative — total CPU time over the process's whole lifetime — is a
/// single-sample figure, but it answers a different question ("has this been
/// busy since Tuesday") than the one anyone opens this tool to ask ("what is
/// eating my CPU *now*"), and a browser tab that pinned a core last week would
/// outrank the one pinning it this second.
public struct CPUSampler {

    private struct Sample {
        var cpuSeconds: TimeInterval
        /// The process's start time, kept as an identity check.
        var startTime: Date?
    }

    private var previous: [Int32: Sample] = [:]
    private var previousTaken: Date?

    public init() {}

    /// Whether a percentage can be produced yet. False before the second scan.
    public var hasBaseline: Bool { previousTaken != nil }

    /// Fill in `cpuPercent` on each record from the change since the last call,
    /// then keep this scan as the next baseline.
    ///
    /// - Parameter now: the moment this scan was taken. Injectable so the
    ///   arithmetic can be tested without sleeping.
    public mutating func annotate(_ records: inout [ProcessRecord], now: Date = Date()) {
        defer {
            previous = Dictionary(
                records.map { ($0.pid, Sample(cpuSeconds: $0.cpuSeconds ?? 0, startTime: $0.startTime)) },
                uniquingKeysWith: { first, _ in first }
            )
            previousTaken = now
        }
        guard let taken = previousTaken else { return }
        let elapsed = now.timeIntervalSince(taken)
        // A zero or backwards interval would divide by nothing. It happens when
        // two scans land in the same instant, and it must produce "unknown"
        // rather than infinity.
        guard elapsed > 0.001 else { return }

        for index in records.indices {
            guard let cpuSeconds = records[index].cpuSeconds,
                  let last = previous[records[index].pid] else { continue }
            // pids are reused. A pid whose start time changed is a *different*
            // process wearing the same number, and subtracting the old one's
            // counter from it would report a wild negative or a nonsense spike.
            guard last.startTime == records[index].startTime else { continue }
            let used = cpuSeconds - last.cpuSeconds
            // A counter that went backwards can only mean the identity check
            // above let something through; report nothing rather than a lie.
            guard used >= 0 else { continue }
            records[index].cpuPercent = used / elapsed * 100
        }
    }

    /// Forget the baseline — for a caller that has paused long enough that the
    /// next interval would be meaningless.
    public mutating func reset() {
        previous.removeAll()
        previousTaken = nil
    }
}
