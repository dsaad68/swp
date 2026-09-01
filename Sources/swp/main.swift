import Foundation
import swpCore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Argument parsing

let options: Options
switch Options.parse(CommandLine.arguments.dropFirst()) {
case .success(let parsed):
    options = parsed
case .failure(let message, let code):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

if options.showHelp {
    print(Options.usage)
    exit(0)
}
if options.showVersion {
    print("swp \(appVersion)")
    exit(0)
}

// MARK: - Colour

// Three ways to end up monochrome, and all of them are honoured: the flag, the
// convention (`NO_COLOR`, any value), and a redirected stdout — escape codes in
// a file are noise, and in a pipe they break the `grep` they were piped into.
let stdoutIsTTY = isatty(STDOUT_FILENO) != 0
Ansi.colorEnabled = !options.noColor
    && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
    && stdoutIsTTY
if let colorterm = ProcessInfo.processInfo.environment["COLORTERM"]?.lowercased() {
    Ansi.truecolor = colorterm.contains("truecolor") || colorterm.contains("24bit")
}
let theme = Ansi.colorEnabled ? Theme.named(options.themeName) : Theme.mono

/// Output width. A terminal's own width when there is one; otherwise wide
/// enough that nothing is truncated, since trailing padding is trimmed and a
/// pipe has no margin to respect.
let outputWidth = options.width ?? (stdoutIsTTY ? Terminal.size().cols : 10_000)

// MARK: - What to do

/// Whether this run needs a CPU rate — and so a second sample.
///
/// Only when the sort asks for one. A rate cannot be read, it has to be
/// measured across an interval, and making every `swp -p 3000` wait a quarter
/// of a second for a column it did not ask for would be a poor trade for a
/// lookup that otherwise answers in 30 ms.
let needsCPU = options.sort == .cpu

/// How long to wait between the two samples a CPU rate is measured over.
///
/// Long enough that a process which woke, worked and slept inside the window is
/// represented fairly, short enough to feel like an answer rather than a job.
/// `top -l 2` uses one second; a quarter is the shortest that still separates a
/// busy process from a merely awake one.
let cpuSampleInterval: TimeInterval = 0.25

/// Scan and apply the command-line query, in the order the listing wants.
func matches() -> (records: [ProcessRecord], incomplete: Bool) {
    let scanOptions = ProcessScanner.Options(includePortless: options.includePortless,
                                             user: options.user)
    var sampler = CPUSampler()
    var result = ProcessScanner.scan(scanOptions)

    if needsCPU {
        // The first scan is only a baseline; its counters are cumulative and
        // say nothing about now.
        var baseline = result.processes
        sampler.annotate(&baseline)
        Thread.sleep(forTimeInterval: cpuSampleInterval)
        result = ProcessScanner.scan(scanOptions)
    }
    sampler.annotate(&result.processes)

    var records = options.query.filter(result.processes).sorted(by: options.sort)
    // Applied after the sort, which is the only order in which "top 5" means
    // anything, and after the filter, so `swp --cpu --top 5 node` is the five
    // busiest *node* processes rather than whichever of the five busiest happen
    // to be node.
    if let top = options.top, records.count > top {
        records = Array(records.prefix(top))
    }
    return (records, result.portsIncomplete)
}

/// Say why an empty result is empty. "Nothing found" is true but useless when
/// the reason is that the port belongs to another user and we are not root, or
/// that the process holds no port and `-a` was not given.
func explainEmpty(incomplete: Bool) {
    var reasons: [String] = []
    reasons.append(options.query.isEmpty ? "nothing is listening" : "nothing matches that query")
    // The `-a` hint belongs only to a bare browse. A named target already
    // implies it, and telling someone whose `swp 9999` found nothing that
    // portless processes are hidden is worse than saying nothing: no portless
    // process could ever match a port.
    if options.query.isEmpty, !options.includePortless {
        reasons.append("processes with no port are hidden — add -a")
    }
    if incomplete { reasons.append("other users' ports need sudo") }
    FileHandle.standardError.write(Data(("swp: " + reasons.joined(separator: "; ") + "\n").utf8))
}

/// Print the listing and exit.
func runList() -> Never {
    let (records, incomplete) = matches()
    if options.json {
        print(Report.json(for: records))
        exit(records.isEmpty ? 1 : 0)
    }
    guard !records.isEmpty else {
        explainEmpty(incomplete: incomplete)
        exit(1)
    }
    for line in Report.lines(for: records, theme: theme, width: outputWidth, showCPU: needsCPU) {
        print(line)
    }
    exit(0)
}

/// Signal everything that matched.
///
/// Refuses to guess at scale: without `--yes` it names every target and asks
/// once. With stdin redirected there is nobody to ask, so it stops and says
/// which flag would have let it proceed rather than acting unasked.
func runKill() -> Never {
    let (records, incomplete) = matches()
    guard !records.isEmpty else {
        explainEmpty(incomplete: incomplete)
        exit(1)
    }

    if !options.assumeYes {
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(Data(
                "swp: refusing to signal \(records.count) process(es) without a terminal to ask — pass --yes\n".utf8
            ))
            exit(1)
        }
        print("Send \(options.signal.displayName) to:")
        for record in records { print("  \(Report.describe(record))") }
        print("Continue? [y/N] ", terminator: "")
        // Line-buffered stdout would hold the prompt back until after the read.
        fflush(stdout)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard answer == "y" || answer == "yes" else {
            print("cancelled")
            exit(1)
        }
    }

    var failed = false
    for record in records {
        let (outcome, exited) = Killer.sendAndConfirm(options.signal, to: record)
        if !outcome.succeeded { failed = true }
        print(Report.outcomeLine(outcome, exited: exited, theme: theme))
    }
    exit(failed ? 1 : 0)
}

switch options.mode {
case .list:
    runList()
case .kill:
    runKill()
case .pick:
    // A keyboard UI needs a terminal at both ends. With either redirected the
    // useful non-interactive answer is the listing — the same choice termdown
    // makes when its pager has nothing to page.
    guard Terminal.isInteractive else { runList() }
    var menu = ProcessMenu(
        theme: theme,
        signal: options.signal,
        sort: options.sort,
        includePortless: options.includePortless,
        user: options.user,
        initialQuery: options.query,
        limit: options.top
    )
    exit(Terminal.withUI(mouse: true) { menu.run() })
}
