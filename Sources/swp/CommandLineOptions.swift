import Foundation
import swpCore

/// Everything the command line asked for.
///
/// Parsing returns this (or a message and an exit code) rather than calling
/// `exit` itself, so every flag combination — including the ones that are
/// mistakes — can be tested without spawning a process.
struct Options: Equatable {

    /// What to do once the arguments are understood.
    enum Mode: Equatable {
        /// Open the interactive picker, pre-filtered by the query.
        case pick
        /// Print the matches and exit.
        case list
        /// Signal the matches and exit.
        case kill
    }

    var mode: Mode = .pick
    var query = Query()
    var includePortless = false
    var user: uid_t?
    var signal: Signal = .term
    /// Skip the confirmation before killing. Only ever set explicitly: the
    /// default is to ask, because the default is irreversible.
    var assumeYes = false
    var sort: ProcessSort = .port
    var json = false
    var width: Int?
    var themeName: String?
    var noColor = false
    var showHelp = false
    var showVersion = false

    enum ParseResult: Equatable {
        case success(Options)
        case failure(message: String, code: Int32)
    }

    /// Parse arguments, excluding argv[0].
    static func parse(_ arguments: some Sequence<String>) -> ParseResult {
        var options = Options()
        var args = ArraySlice(Array(arguments))
        /// The token that named the mode, so a second, *different* one can say
        /// which two were combined rather than silently picking a winner. The
        /// same mode twice — `-l --list` — is a redundancy, not a mistake.
        var modeNamedBy: String?

        /// Pull the value that follows a flag, refusing one that looks like
        /// another flag. `swp --signal --json` used to send SIG`--json`.
        func value(for flag: String) -> String? {
            guard let next = args.first, !next.hasPrefix("-") || Int(next) != nil else { return nil }
            args = args.dropFirst()
            return next
        }

        func claimMode(_ mode: Mode, _ token: String) -> String? {
            if let previous = modeNamedBy, options.mode != mode {
                return "swp: \(token) cannot be combined with \(previous)"
            }
            modeNamedBy = token
            options.mode = mode
            return nil
        }

        while let arg = args.first {
            args = args.dropFirst()
            switch arg {
            case "-h", "--help":
                options.showHelp = true
            case "-V", "--version":
                options.showVersion = true

            case "-p", "--port":
                guard let raw = value(for: arg), let port = UInt16(raw) else {
                    return .failure(message: "swp: \(arg) requires a port number (0–\(Query.maxPort))", code: 1)
                }
                options.query.ports.append(port)
            case "-n", "--name":
                guard let text = value(for: arg) else {
                    return .failure(message: "swp: \(arg) requires a name", code: 1)
                }
                options.query.terms.append(text)
            case "--pid":
                guard let raw = value(for: arg), let pid = Int32(raw) else {
                    return .failure(message: "swp: --pid requires a process id", code: 1)
                }
                options.query.pids.append(pid)

            case "-u", "--user":
                guard let name = value(for: arg) else {
                    return .failure(message: "swp: \(arg) requires a user name or uid", code: 1)
                }
                guard let uid = UserNames.uid(forName: name) else {
                    return .failure(message: "swp: no such user '\(name)'", code: 1)
                }
                options.user = uid
            case "--me":
                options.user = getuid()

            case "-a", "--all":
                options.includePortless = true
            case "-l", "--list":
                if let conflict = claimMode(.list, arg) { return .failure(message: conflict, code: 1) }
            case "-k", "--kill":
                if let conflict = claimMode(.kill, arg) { return .failure(message: conflict, code: 1) }

            case "-s", "--signal":
                guard let raw = value(for: arg) else {
                    return .failure(message: "swp: \(arg) requires a signal name or number", code: 1)
                }
                guard let signal = Signal.parse(raw) else {
                    let names = Signal.known.map(\.name).joined(separator: ", ")
                    return .failure(message: "swp: unknown signal '\(raw)' (try one of: \(names))", code: 1)
                }
                options.signal = signal
            case "-9":
                options.signal = .kill
            case "-y", "--yes":
                options.assumeYes = true

            case "--sort":
                guard let raw = value(for: arg), let order = ProcessSort(rawValue: raw.lowercased()) else {
                    let names = ProcessSort.allCases.map(\.rawValue).joined(separator: ", ")
                    return .failure(message: "swp: --sort takes one of: \(names)", code: 1)
                }
                options.sort = order
            case "--json":
                options.json = true
                // JSON is only ever a listing: a picker cannot emit it, and a
                // kill's output is a report on something that already happened.
                if modeNamedBy == nil { options.mode = .list }

            case "--width":
                guard let raw = value(for: arg), let width = Int(raw), width > 0 else {
                    return .failure(message: "swp: --width requires a positive number", code: 1)
                }
                options.width = width
            case "--theme":
                guard let name = value(for: arg) else {
                    return .failure(message: "swp: --theme requires a name (\(Theme.names.joined(separator: ", ")))", code: 1)
                }
                options.themeName = name
            case "--no-color":
                options.noColor = true

            default:
                // A bare word is part of the query. Anything else beginning with
                // a dash is a typo, and a typo must not be silently searched for
                // — `swp --kil node` would otherwise list node and look like it
                // had failed to kill it.
                guard !arg.hasPrefix("-") else {
                    return .failure(message: "swp: unknown option \(arg)\nTry 'swp --help'.", code: 1)
                }
                options.query.merge(Query.classify(arg))
            }
        }

        // A query that names a program or a pid is not browsing — it is looking
        // for one thing, and hiding it because it holds no port would be
        // perverse. `swp -k --pid 4123` failed outright before this, and
        // `swp chrome` found nothing on a machine plainly running Chrome. The
        // ports-only default is what keeps the *unfiltered* list to two dozen
        // readable rows; it has no business narrowing a search. A port query is
        // unaffected either way — only a listener can match one.
        if !options.query.terms.isEmpty || !options.query.pids.isEmpty {
            options.includePortless = true
        }
        return .success(options)
    }

    /// `--help`. Kept beside the parser so a flag and its documentation are
    /// edited in one place.
    static let usage = """
    swp — find what's holding a port, and kill it

    USAGE: swp [options] [query …]
           swp                     pick from everything holding a port
           swp 3000                whatever is on port 3000
           swp node                processes named — or running — node
           swp -a                  every process, port or not
           swp -l 3000             print the matches instead of picking
           swp -k 3000             kill what's on port 3000

    QUERY:
      A bare number is a port; above \(Query.maxPort) it is a process id. Any
      other word is matched against the program name, then its full command
      line, then the user. Extra words narrow: `swp node 3000`.

    OPTIONS:
      -p, --port N       Match port N (repeatable)
      -n, --name TEXT    Match TEXT in the name or command (repeatable)
          --pid N        Match process id N (repeatable)
      -u, --user NAME    Only this user's processes (name or uid)
          --me           Only your own processes
      -a, --all          Include processes that hold no port. Implied whenever
                         a name or --pid is given: only a browse is narrowed to
                         listeners
      -l, --list         Print the matches and exit — never open the picker
      -k, --kill         Signal the matches and exit
      -s, --signal NAME  Signal to send: \(Signal.known.map(\.name).joined(separator: ", "))
                         (default: TERM)
      -9                 Shorthand for --signal KILL
      -y, --yes          Do not ask before signalling
          --sort ORDER   \(ProcessSort.allCases.map(\.rawValue).joined(separator: ", ")) (default: port)
          --json         Machine-readable listing (implies --list)
          --width N      Output width (default: auto-detect)
          --theme NAME   \(Theme.names.joined(separator: ", "))
          --no-color     Disable ANSI colours (also honours NO_COLOR)
      -V, --version      Show version information
      -h, --help         Show this help

    IN THE PICKER:
      ↑/↓ or j/k  move          /  filter        a  all processes / ports only
      Enter or x  send \(Signal.term.displayName)   X  send \(Signal.kill.displayName)  s  change sort order
      y           copy the pid  r  refresh       ?  keys        q  quit

    NOTE: without root, the ports of other users' processes are invisible to
    the kernel calls this uses — run `sudo swp` to see them all.
    """
}
