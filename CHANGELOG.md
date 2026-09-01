# Changelog

All notable changes to swp are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-01

First release.

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

### Notes
- Without root, macOS will not open another user's file descriptors, so their
  ports are invisible. The rows are still listed; the footer says why the PORT
  column is empty, and `sudo swp` fills it in.
- The environment is never read, though `KERN_PROCARGS2` offers it alongside
  the arguments. Environments hold secrets, and this tool prints what it reads.
