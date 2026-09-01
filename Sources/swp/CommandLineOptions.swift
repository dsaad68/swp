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

    /// What to do, once the query is known.
    ///
    /// The default is not fixed: `swp` with nothing to look for is a browse and
    /// opens the picker, and `swp 3000` is a question and gets an answer. See
    /// the note at the end of `parse`.
    var mode: Mode = .pick
    var query = Query()
    var includePortless = false
    var user: uid_t?
    var signal: Signal = .term
    /// Skip the confirmation before killing. Only ever set explicitly: the
    /// default is to ask, because the default is irreversible.
    var assumeYes = false
    var sort: ProcessSort = .port
    /// Keep only the first `top` rows after sorting. `nil` means all of them.
    var top: Int?
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
            case "-i", "--pick":
                if let conflict = claimMode(.pick, arg) { return .failure(message: conflict, code: 1) }
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

            // Shorthands for the two sorts people reach for by name rather than
            // by concept: "what is eating my CPU", "what is eating my RAM".
            //
            // Both imply --all, because both are questions about the machine
            // rather than about its listeners, and "the five busiest processes"
            // restricted to the ones holding a port is a strange answer to a
            // question nobody asked that way. `--sort cpu` stays a pure sort
            // modifier for anyone who did mean it about listeners only.
            case "--cpu":
                options.sort = .cpu
                options.includePortless = true
            case "--ram", "--mem", "--memory":
                options.sort = .memory
                options.includePortless = true

            case "-t", "--top":
                guard let raw = value(for: arg), let count = Int(raw), count > 0 else {
                    return .failure(message: "swp: \(arg) requires a positive number", code: 1)
                }
                options.top = count

            // Recognised so the answer is the reason rather than "unknown
            // option". Both are real asks and neither is refusable by a bit of
            // work: they need interfaces that do not exist for us to call.
            case "--net", "--network":
                return .failure(message: Self.networkUnavailable, code: 1)
            case "--gpu":
                return .failure(message: Self.gpuUnavailable, code: 1)

            case "--sort", "--json", "--width", "--theme", "--no-color":
                // Presentation, handled apart purely to keep this function
                // inside the body-length ceiling — the switch grows a case per
                // flag and had outgrown it.
                switch options.applyPresentation(arg, value: { value(for: $0) },
                                                 modeAlreadyNamed: modeNamedBy != nil) {
                case .none: break
                case .some(let message): return .failure(message: message, code: 1)
                }

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

        // A query is a question, and a question deserves an answer, not a
        // full-screen program. `swp 3000` prints what is on 3000 and exits;
        // only a bare `swp` — nothing named, nothing to look up — takes over
        // the terminal to browse. That keeps the tool usable inside a pipeline,
        // a script and a subshell without anyone reaching for a flag, which is
        // the behaviour a command-line tool is expected to have.
        //
        // `-i` asks for the picker anyway, when the query is a starting point
        // rather than the whole question: `swp -i node` opens the list already
        // narrowed, ready for another keystroke.
        if modeNamedBy == nil, !options.query.isEmpty {
            options.mode = .list
        }
        // `--top N` names a quantity of *answer*, which only means something in
        // output: `swp --cpu --top 5` is a question about the five busiest, not
        // a request to browse. A sort order alone is not — `swp --cpu` opening
        // the picker sorted by CPU is a browse, and a useful one.
        if modeNamedBy == nil, options.top != nil {
            options.mode = .list
        }
        return .success(options)
    }

    /// Handle one presentation flag, returning a message if it was malformed.
    ///
    /// - Parameter value: pulls the flag's argument, refusing one that looks
    ///   like another flag — the caller owns the argument cursor.
    /// - Parameter modeAlreadyNamed: whether `-l`/`-k`/`-i` has been seen, so
    ///   `--json` knows whether it may set one.
    private mutating func applyPresentation(_ flag: String, value: (String) -> String?,
                                            modeAlreadyNamed: Bool) -> String? {
        switch flag {
        case "--sort":
            guard let raw = value(flag), let order = ProcessSort(rawValue: raw.lowercased()) else {
                let names = ProcessSort.allCases.map(\.rawValue).joined(separator: ", ")
                return "swp: --sort takes one of: \(names)"
            }
            sort = order
        case "--json":
            json = true
            // JSON is only ever a listing: a picker cannot emit it, and a
            // kill's output is a report on something that already happened.
            if !modeAlreadyNamed { mode = .list }
        case "--width":
            guard let raw = value(flag), let width = Int(raw), width > 0 else {
                return "swp: --width requires a positive number"
            }
            self.width = width
        case "--theme":
            guard let name = value(flag) else {
                return "swp: --theme requires a name (\(Theme.names.joined(separator: ", ")))"
            }
            themeName = name
        case "--no-color":
            noColor = true
        default:
            return "swp: unknown option \(flag)"
        }
        return nil
    }

    /// Why `--net` cannot be answered. Recognised rather than left to fall
    /// through as an unknown option: it is a reasonable thing to ask for, and
    /// the useful reply is the reason, not a shrug.
    static let networkUnavailable = """
    swp: per-process network usage is not available to a program like this.
         macOS publishes it only through NetworkStatistics.framework, which is
         private API — it is what nettop and Activity Monitor use. Linux has no
         per-process byte counter at all: /proc/<pid>/net/dev is per network
         namespace, so tools like nethogs capture packets and attribute them by
         socket inode, which needs root.
         `swp -a` still shows which ports a process holds.
    """

    /// The same, for `--gpu`.
    static let gpuUnavailable = """
    swp: per-process GPU usage is not available to a program like this.
         Activity Monitor reads it through private IOAccelerator accounting; the
         public IOKit registry reports per-*device* utilisation, not per process.
         On Linux it exists only per vendor (NVML, and NVIDIA only).
    """

    /// `--help`. Kept beside the parser so a flag and its documentation are
    /// edited in one place.
    static let usage = """
    swp — find what's holding a port, and kill it

    USAGE: swp [options] [query …]
           swp                     pick from everything holding a port
           swp 3000                print whatever is on port 3000, and exit
           swp node                print processes named — or running — node
           swp -a                  pick from every process, port or not
           swp -i 3000             open the picker on port 3000 instead
           swp -k 3000             kill what's on port 3000
           swp --cpu --top 5       the five busiest processes, printed
           swp --ram -t 10         the ten largest by memory

    A query answers and exits; a bare `swp` opens the picker. So `swp 3000`
    prints, and pipes and scripts need no flag — while `swp` alone still
    browses, and `-i` opens the picker on a query.

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
          --cpu          Busiest first, across every process (= --sort cpu -a)
          --ram          Largest first, across every process (= --sort memory -a)
      -t, --top N        Keep only the first N rows, and print them
      -a, --all          Include processes that hold no port. Implied whenever
                         a name or --pid is given: only a browse is narrowed to
                         listeners
      -l, --list         Print the matches and exit — never open the picker
      -i, --pick         Open the picker even though a query was given
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

    CPU is a share of one core over a sampled interval, the way top reports
    it, so it can exceed 100% on a process using more than one. Asking for it
    on the command line costs a second sample (about a quarter of a second);
    the picker re-scans anyway, so there it is free and always shown.

    NOTE: without root, the ports, memory and CPU of other users' processes are
    invisible to the kernel calls this uses — run `sudo swp` to see them all.
    """
}
