# Changelog

All notable changes to swp are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-01

First release. Nothing was published before this, so everything below shipped
together; the entries are grouped by what they are rather than by when they
landed during development.

### Added

- **A picker over the processes holding a port.** `swp` with no arguments opens
  a bordered, arrow-key list of everything listening, refreshed every two
  seconds. `/` filters fuzzily across every column at once — name, port, pid,
  user, command — and the matched characters are picked out in the row. `Enter`
  or `x` sends `SIGTERM`, `X` sends `SIGKILL`, and both ask first, naming the
  process three ways so a misread row cannot become a killed one.

  `j`/`k` move and `x` kills, deliberately never the other way round: a tool
  that kills on the twin of the up-arrow will one day kill the wrong thing.

  The list follows the cursor by pid rather than by index, so a process exiting
  above the cursor cannot slide a different row underneath it between the
  keystroke and the signal.

- **A one-shot command line.** `swp -l` prints the matches, `swp -k` signals
  them, `--json` emits a machine-readable listing, and `--signal` / `-9` pick
  what to send. With stdout or stdin redirected the picker falls back to the
  listing rather than painting a frame into a pipe or blocking on a key that
  cannot arrive.

- **A query that reads the way people type.** A bare number is a port; above
  65535 it can only be a pid, so it is one. Any other word matches the name,
  then the command line, then the user. Extra words narrow. When anything
  matches by *name*, command-line-only matches are dropped — `swp node` should
  not offer six VS Code helpers whose arguments mention `node.mojom` to a
  command that can end in `--kill`.

- **Native scanning on macOS and Linux.** No `lsof`, no `ps`, no subprocesses:
  `sysctl(KERN_PROC_ALL)` plus `libproc` on macOS, `/proc` on Linux, with
  sockets joined to processes through file descriptors (macOS) or socket inodes
  (Linux). A full scan of ~1000 processes takes about 12 ms, which is what
  makes a self-refreshing list affordable.

- **Only bound local endpoints.** A TCP socket in `LISTEN` or a UDP socket with
  a local port. Established connections are excluded: "who has 3000?" means the
  server, not the browser sockets talking to it.

- **A termdown-shaped header in its own palette.** The same rounded frame,
  wordmark and boxed filter field, drawn teal → amber rather than blue → mauve.
  A terminal under 22 rows gets a compact header instead — eleven lines of
  masthead on a short window would leave three rows of list.

- **A tag-driven release pipeline** (`.github/workflows/release.yml`) that
  builds a universal macOS binary and a Linux x86_64 one, publishes a GitHub
  Release with notes taken from this file, and pushes a rendered formula to
  [dsaad68/homebrew-tap](https://github.com/dsaad68/homebrew-tap) — so
  `brew install dsaad68/tap/swp` works. Documented in `docs/releasing.md`;
  `just tag` is the whole ceremony, and `just preflight` is what to run first.
- **`just linux-build` / `just linux-test`** run the Linux build and test suite
  in a `swift:6.2` container. swp's Linux scanner is behind
  `#if !canImport(Darwin)`, so a macOS build never compiles it.

- **Sort by CPU and by memory, and `--top N`.** `swp --cpu --top 5` prints the
  five busiest processes; `swp --ram -t 10` the ten largest. Both shorthands
  imply `-a`, because "what is eating my CPU" is a question about the machine
  rather than about its listeners; `--sort cpu` stays a pure modifier for anyone
  who did mean it about listeners only. `--top` implies printing, since a
  quantity of answer only means something in output.

  CPU is a share of one core over a sampled interval, the way `top` reports it,
  so it exceeds 100% on a process using more than one core. It cannot be read
  from a single sample — macOS's `kinfo_proc.p_pctcpu` is hard zero on anything
  modern, Linux publishes only a cumulative counter — so the command line takes
  a second sample, about a quarter of a second, and only when asked. The picker
  re-scans anyway, so there the column is free and always shown; its first
  refresh is brought forward to 0.25 s so the numbers arrive promptly rather
  than after a full interval.

  On macOS the CPU counter rides along in the `proc_taskinfo` call already made
  for resident size, so it costs no extra syscall — and is refused on the same
  processes, which is why MEM and CPU go blank on the same rows.

  The sampler checks each pid's start time before differencing. pids are reused,
  and subtracting a dead process's counter from the live one wearing its number
  reports a wild spike or a negative.

- **`--net` and `--gpu` explain themselves.** Both were asked for and neither is
  obtainable: macOS publishes per-process network only through the private
  `NetworkStatistics.framework`, Linux has no per-process byte counter at all,
  and per-process GPU is private `IOAccelerator` accounting on macOS and
  vendor-only (NVML) on Linux. The flags are recognised and answer with the
  reason rather than "unknown option".

### Changed during development

These describe behaviour that changed before anything was published, kept
because the reasoning is the useful part.

- **A query now answers and exits instead of opening the picker.** `swp 3000`
  and `swp -p 3000` print the matching rows to stdout and stop; only a bare
  `swp` — nothing named, nothing to look up — takes over the terminal. A
  command-line tool is expected to work inside a pipeline, a script and a
  subshell without a flag for it, and requiring `-l` to get an answer made the
  common case the awkward one.

  `-i` / `--pick` opens the picker anyway, for when the query is a starting
  point rather than the whole question: `swp -i node` opens the list already
  narrowed. Filters (`--me`, `-u`, `-a`) are not queries — they narrow a browse
  rather than naming a target, so they still open the picker.

- `TableLayout` is built around a `Column` enum rather than five arrays indexed
  in parallel. The set of columns is no longer fixed — CPU appears only when a
  rate was measured — and inserting a conditional column into parallel arrays is
  how off-by-one bugs are made.

### Fixed

- The Linux CI job had failed on **every commit since the first** and nobody had
  looked. The scanner itself was fine; the socket test did not build under
  Glibc, where `SOCK_STREAM` is a `__socket_type` rather than an `Int32` and
  `Darwin.bind` does not exist. Both are now behind a small platform shim.
- The empty-result message no longer suggests `-a` after a *port* query. No
  portless process can match a port, so "processes with no port are hidden" was
  worse than saying nothing there.

### Notes

- Without root, macOS will not open another user's file descriptors, so their
  ports are invisible. The rows are still listed; the footer says why the PORT
  column is empty, and `sudo swp` fills it in.
- The environment is never read, though `KERN_PROCARGS2` offers it alongside
  the arguments. Environments hold secrets, and this tool prints what it reads.
