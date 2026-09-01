import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The public front door: one call that returns every process, with the ports
/// each one holds already attached.
public enum ProcessScanner {

    /// What to collect. Keeping this a value means the picker can re-scan with
    /// a changed view (`a` toggles `includePortless`) without either side
    /// knowing how the other works.
    public struct Options: Equatable, Sendable {
        /// Include processes that hold no bound port. Off by default: the
        /// question `swp` exists to answer is "who has this port", and a
        /// thousand-row list of everything buries it.
        public var includePortless: Bool
        /// Restrict to one uid. `nil` means every user.
        public var user: uid_t?
        /// Leave `swp` itself out. Always wanted in practice — the tool is
        /// never the answer — but explicit so tests can find themselves.
        public var excludeSelf: Bool

        public init(includePortless: Bool = false, user: uid_t? = nil, excludeSelf: Bool = true) {
            self.includePortless = includePortless
            self.user = user
            self.excludeSelf = excludeSelf
        }
    }

    /// A scan, plus what the kernel would not tell us.
    public struct Result: Sendable {
        public var processes: [ProcessRecord]
        /// True when socket information was refused or skipped for processes we
        /// do not own — i.e. the port column is complete only for your own
        /// processes. The UI turns this into one line of footer rather than
        /// leaving the user to wonder why `sudo lsof` disagrees.
        public var portsIncomplete: Bool

        public init(processes: [ProcessRecord], portsIncomplete: Bool = false) {
            self.processes = processes
            self.portsIncomplete = portsIncomplete
        }
    }

    /// Scan the machine.
    ///
    /// The two halves are separate on purpose: naming processes is cheap and
    /// always allowed, while opening their file descriptors is neither. So the
    /// process list is gathered first and the socket pass runs only over the
    /// pids it could possibly succeed for — which, unless we are root, is our
    /// own. Asking about the rest would cost two syscalls each for a guaranteed
    /// `EPERM`, and on a busy machine that is thousands of them per refresh.
    public static func scan(_ options: Options = Options()) -> Result {
        var processes = platformProcesses()
        let me = getpid()
        if options.excludeSelf { processes.removeAll { $0.pid == me } }
        if let user = options.user { processes.removeAll { $0.uid != user } }

        let root = getuid() == 0
        let inspectable = processes.filter { root || $0.isOwnedByCurrentUser }.map(\.pid)
        var incomplete = inspectable.count != processes.count

        let (map, denied) = platformListeners(for: inspectable)
        if denied { incomplete = true }
        for i in processes.indices {
            processes[i].listeners = map[processes[i].pid] ?? []
        }

        if !options.includePortless { processes.removeAll { !$0.hasPorts } }
        return Result(processes: processes, portsIncomplete: incomplete)
    }

    /// Look up a single process by pid — what `swp kill 4123` needs to name the
    /// thing it is about to signal, without paying for a full scan.
    public static func process(pid: Int32) -> ProcessRecord? {
        // Cheap enough at one pid, and it keeps the platform seam in one place.
        var found = platformProcesses().first { $0.pid == pid }
        if found != nil {
            let (map, _) = platformListeners(for: [pid])
            found?.listeners = map[pid] ?? []
        }
        return found
    }

    // MARK: - Platform seam

    private static func platformProcesses() -> [ProcessRecord] {
        #if canImport(Darwin)
        return DarwinScanner.processes()
        #elseif canImport(Glibc)
        return LinuxScanner.processes()
        #else
        return []
        #endif
    }

    private static func platformListeners(for pids: [Int32]) -> (map: [Int32: [Listener]], denied: Bool) {
        guard !pids.isEmpty else { return ([:], false) }
        #if canImport(Darwin)
        return DarwinScanner.listeners(for: pids)
        #elseif canImport(Glibc)
        return LinuxScanner.listeners(for: pids)
        #else
        return ([:], false)
        #endif
    }
}
