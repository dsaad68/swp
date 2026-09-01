import Foundation

/// One running process, as much of it as the platform will tell us.
///
/// Fields the kernel refuses for a process we do not own (the full argument
/// vector, and on macOS the open sockets) are optional or empty rather than
/// absent: a row for a process you cannot inspect is still a row you may need
/// to see, and hiding it would make `swp` quietly disagree with `ps`.
public struct ProcessRecord: Equatable, Sendable {

    public var pid: Int32
    public var ppid: Int32
    /// The executable's own name — `node`, `Google Chrome Helper`. This is what
    /// a name query matches first, and what the list shows in its widest column.
    public var name: String
    /// Absolute path to the executable, when it could be read.
    public var path: String
    /// Full argument vector including argv[0], when readable. Empty otherwise.
    public var arguments: [String]
    public var uid: uid_t
    /// Login name for `uid`, falling back to the numeric uid as text.
    public var user: String
    /// When the process was started, when the platform reports it.
    public var startTime: Date?
    /// Resident set size in bytes, when the platform reports it.
    public var memoryBytes: UInt64?
    /// Bound local endpoints, already merged. Empty for the great majority of
    /// processes, which is exactly what the default (ports-only) view filters on.
    public var listeners: [Listener]

    public init(pid: Int32, ppid: Int32 = 0, name: String, path: String = "",
                arguments: [String] = [], uid: uid_t = 0, user: String = "",
                startTime: Date? = nil, memoryBytes: UInt64? = nil,
                listeners: [Listener] = []) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.arguments = arguments
        self.uid = uid
        self.user = user
        self.startTime = startTime
        self.memoryBytes = memoryBytes
        self.listeners = listeners
    }
}

public extension ProcessRecord {

    /// The command line as one string, or the executable path when the argument
    /// vector could not be read (another user's process, without root).
    var commandLine: String {
        arguments.isEmpty ? path : arguments.joined(separator: " ")
    }

    /// Everything a fuzzy query is matched against, joined once.
    ///
    /// Built from the parts rather than from `commandLine` so the pid, the user
    /// and the ports are searchable too: `swp 5432 postgres` and `swp dsaad node`
    /// both work, and typing a pid into the picker's filter narrows to it.
    var searchText: String {
        var parts = [name, path, user, String(pid)]
        parts.append(contentsOf: arguments.dropFirst().filter { !$0.isEmpty })
        parts.append(contentsOf: listeners.map { String($0.port) })
        return parts.joined(separator: " ")
    }

    /// True when the process holds at least one bound endpoint.
    var hasPorts: Bool { !listeners.isEmpty }

    /// The lowest port it holds, for sorting. Portless rows sort last rather
    /// than first, which is what `UInt16.max` buys.
    var primaryPort: UInt16 { listeners.map(\.port).min() ?? UInt16.max }

    /// Whether this is one of our own processes. On macOS the socket scan can
    /// only see these without root, so the picker uses it to explain an empty
    /// list rather than leaving the user staring at one.
    var isOwnedByCurrentUser: Bool { uid == getuid() }

    /// The arguments after argv[0]: `--hot scripts/serve.ts`.
    ///
    /// Empty entries are dropped. A process that rewrites its own argv (Raycast
    /// does, and so does every process that renames itself) leaves NUL padding
    /// behind it, which joined unfiltered into a string of spaces that read as
    /// a bug in the column that showed it.
    var argumentSummary: String {
        arguments.dropFirst().filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// How the list is ordered. The picker cycles through these with `s`; the
/// non-interactive listing takes one with `--sort`.
public enum ProcessSort: String, CaseIterable, Sendable {
    case port
    case pid
    case name
    case memory
    case started

    /// The next order in the cycle, wrapping.
    public var next: ProcessSort {
        let all = ProcessSort.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// Human label for the header row.
    public var label: String {
        switch self {
        case .port:    return "port"
        case .pid:     return "pid"
        case .name:    return "name"
        case .memory:  return "memory"
        case .started: return "started"
        }
    }
}

public extension Array where Element == ProcessRecord {

    /// Sort in place of the caller, with pid as the tiebreaker throughout.
    ///
    /// Every comparison falls back to the pid because a list that reorders
    /// equal rows between refreshes moves the cursor out from under the user
    /// mid-keystroke — and the keystroke they were about to press kills things.
    func sorted(by order: ProcessSort) -> [ProcessRecord] {
        switch order {
        case .port:
            return sorted { ($0.primaryPort, $0.pid) < ($1.primaryPort, $1.pid) }
        case .pid:
            return sorted { $0.pid < $1.pid }
        case .name:
            return sorted {
                let l = $0.name.lowercased(), r = $1.name.lowercased()
                return l == r ? $0.pid < $1.pid : l < r
            }
        case .memory:
            return sorted {
                let l = $0.memoryBytes ?? 0, r = $1.memoryBytes ?? 0
                return l == r ? $0.pid < $1.pid : l > r   // biggest first
            }
        case .started:
            return sorted {
                let l = $0.startTime ?? .distantPast, r = $1.startTime ?? .distantPast
                return l == r ? $0.pid < $1.pid : l > r   // newest first
            }
        }
    }
}
