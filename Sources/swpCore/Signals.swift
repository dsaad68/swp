import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The signals worth naming, and the spellings a user might type for them.
public struct Signal: Equatable, Sendable {

    public var number: Int32
    /// Canonical short name, without the `SIG` prefix: `TERM`, `KILL`.
    public var name: String

    public init(number: Int32, name: String) {
        self.number = number
        self.name = name
    }

    /// The default. `TERM` asks the process to shut down and lets it do so —
    /// flush its buffers, close its port, tell its children. `swp` sends this
    /// unless told otherwise, and offers `KILL` one keystroke away for when it
    /// does not work.
    public static let term = Signal(number: SIGTERM, name: "TERM")
    /// The one that cannot be caught, and therefore cannot clean up. Never the
    /// default, always available.
    public static let kill = Signal(number: SIGKILL, name: "KILL")
    public static let interrupt = Signal(number: SIGINT, name: "INT")
    public static let hangup = Signal(number: SIGHUP, name: "HUP")
    public static let quit = Signal(number: SIGQUIT, name: "QUIT")
    public static let stop = Signal(number: SIGSTOP, name: "STOP")
    public static let cont = Signal(number: SIGCONT, name: "CONT")
    public static let user1 = Signal(number: SIGUSR1, name: "USR1")
    public static let user2 = Signal(number: SIGUSR2, name: "USR2")

    public static let known: [Signal] = [
        .hangup, .interrupt, .quit, .kill, .term, .stop, .cont, .user1, .user2,
    ]

    /// Parse `TERM`, `SIGTERM`, `term`, `15`, or `9`.
    ///
    /// Numbers are accepted for the same reason `kill` accepts them — muscle
    /// memory — but only within the range signals occupy, so a stray argument
    /// cannot become `kill -0` and silently do nothing.
    public static func parse(_ text: String) -> Signal? {
        let raw = text.uppercased()
        let stripped = raw.hasPrefix("SIG") ? String(raw.dropFirst(3)) : raw
        if let match = known.first(where: { $0.name == stripped }) { return match }
        guard let number = Int32(stripped), (1...31).contains(number) else { return nil }
        return known.first { $0.number == number }
            ?? Signal(number: number, name: String(number))
    }

    /// `SIGTERM`, for messages.
    public var displayName: String { "SIG\(name)" }
}

/// Sending signals, and saying plainly what came back.
public enum Killer {

    /// Why a signal did not land.
    public enum Failure: Equatable, Sendable {
        /// The process is gone — it exited between the scan and the keystroke,
        /// which on a list that refreshes is ordinary rather than exceptional.
        case noSuchProcess
        /// Another user's process, and we are not root.
        case notPermitted
        /// Refused before it was sent: killing init takes the machine down, and
        /// no interactive list is a good enough reason.
        case refusedInit
        case other(code: Int32)

        public var message: String {
            switch self {
            case .noSuchProcess: return "no such process (it already exited)"
            case .notPermitted:  return "operation not permitted — try again with sudo"
            case .refusedInit:   return "refusing to signal pid 1"
            case .other(let code): return String(cString: strerror(code))
            }
        }
    }

    /// What happened to one process.
    public struct Outcome: Equatable, Sendable {
        public var pid: Int32
        public var name: String
        public var signal: Signal
        /// nil when the signal was delivered.
        public var failure: Failure?

        public init(pid: Int32, name: String, signal: Signal, failure: Failure?) {
            self.pid = pid
            self.name = name
            self.signal = signal
            self.failure = failure
        }

        public var succeeded: Bool { failure == nil }
    }

    /// Send `signal` to `pid`.
    ///
    /// pid 1 is refused outright, and so is anything non-positive: `kill(0, …)`
    /// signals the caller's whole process group and `kill(-1, …)` every process
    /// the user owns, either of which would turn a mistyped pid into a logout.
    /// The kernel would happily do it; the guard is here because nothing in this
    /// tool's purpose ever wants it.
    public static func send(_ signal: Signal, to pid: Int32, name: String = "") -> Outcome {
        guard pid > 1 else {
            return Outcome(pid: pid, name: name, signal: signal, failure: .refusedInit)
        }
        guard kill(pid, signal.number) != 0 else {
            return Outcome(pid: pid, name: name, signal: signal, failure: nil)
        }
        switch errno {
        case ESRCH: return Outcome(pid: pid, name: name, signal: signal, failure: .noSuchProcess)
        case EPERM: return Outcome(pid: pid, name: name, signal: signal, failure: .notPermitted)
        case let code: return Outcome(pid: pid, name: name, signal: signal, failure: .other(code: code))
        }
    }

    /// Send to a scanned process, carrying its name into the result so the
    /// caller can report on something that no longer exists to be looked up.
    public static func send(_ signal: Signal, to record: ProcessRecord) -> Outcome {
        send(signal, to: record.pid, name: record.name)
    }

    /// Whether `pid` is still around. Signal 0 performs the permission and
    /// existence checks without delivering anything, which is exactly the
    /// question "did the TERM work" needs answered.
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means it exists and belongs to someone else.
        return errno == EPERM
    }

    /// Send `signal`, then wait up to `timeout` for the process to actually go.
    ///
    /// A TERM that is caught and ignored looks identical to one that worked
    /// until you check, and "killed it" followed by the port still being busy
    /// is the one outcome this tool must never report. The wait polls rather
    /// than blocking on a child handle because the target is somebody else's
    /// child, not ours — `waitpid` would refuse it.
    public static func sendAndConfirm(_ signal: Signal, to record: ProcessRecord,
                                      timeout: TimeInterval = 2.0) -> (outcome: Outcome, exited: Bool) {
        let outcome = send(signal, to: record)
        guard outcome.succeeded else { return (outcome, false) }
        // STOP and CONT are not meant to end the process, so waiting for it to
        // disappear would always time out and report a failure that isn't one.
        guard signal != .stop, signal != .cont else { return (outcome, false) }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAlive(record.pid) { return (outcome, true) }
            usleep(50_000)
        }
        return (outcome, !isAlive(record.pid))
    }
}
