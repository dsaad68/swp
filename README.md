# swp

[![CI](https://github.com/dsaad68/swp/actions/workflows/ci.yml/badge.svg)](https://github.com/dsaad68/swp/actions/workflows/ci.yml)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Find what is holding a port, and kill it — in **pure Swift**, with no `lsof`,
no `ps`, and no shelling out to anything. `swp` reads the kernel's own process
and socket tables directly, so a full scan of a thousand processes takes about
**12 ms**, which is what lets the picker refresh itself while you look at it.

```
╭──────────────────────────────────────────────────────────────────────────╮
│                                                                          │
│   ╭─╴ ╷ ╷ ╭─╮                                                            │
│   ╰─╮ │ │ ├─╯                                                            │
│   ╶─╯ ╰┴╯ ╵                                                              │
│   26 listening  ·  all users                          by port  ·  v0.1.0 │
│                                                                          │
│  ╭────────────────────────────────────────────────────────────────────╮  │
│  │ ❯ press / to filter — by name, port, pid, anything                 │  │
│  ╰────────────────────────────────────────────────────────────────────╯  │
│ PORT           PID  USER    MEM  UP   NAME              COMMAND          │
│ 3000         49649  dsaad   66M  1d   bun               --hot serve.ts   │
│ 5432          1120  dsaad  212M  4d   postgres          -D /data         │
│ 8080         19074  dsaad   12M  1d   sabacc-server     --addr 127.0.0.1 │
│ 11434         1588  dsaad   27M  4d   ollama            serve            │
│ ↑↓ move · / filter · ⏎ SIGTERM · X SIGKILL · a all · s sort · ? keys     │
╰──────────────────────────────────────────────────────────────────────────╯
```

## Install

Requires a Swift 5.9+ toolchain.

```sh
git clone https://github.com/dsaad68/swp && cd swp
just install          # builds release, symlinks into ~/.local/bin
```

`just install` needs no `sudo`. Make sure `~/.local/bin` is on your `PATH`. To
run from a clone without installing:

```sh
just swp              # the picker
just swp 3000         # what's on 3000, printed
just swp -i node      # the picker, narrowed to node
```

## Use

```sh
swp                   # pick from everything holding a port
swp 3000              # print whatever is on port 3000, and exit
swp node              # print processes named — or running — node
swp -a                # pick from every process, port or not
swp -i 3000           # open the picker on port 3000 instead
swp -k 3000           # kill what's on port 3000 (asks first)
swp -k -9 -y node     # SIGKILL every node, without asking
swp --cpu --top 5     # the five busiest processes
swp --ram -t 10       # the ten largest by memory
swp --json --me       # your processes, machine-readable
```

### CPU and memory

`--cpu` sorts by CPU share and `--ram` by resident memory, busiest and largest
first. Both imply `-a`: "what is eating my CPU" is a question about the machine,
not about its listeners, and answering it from among the processes that happen
to hold a port would be a strange reading. `--sort cpu` stays a pure sort
modifier for anyone who *did* mean it about listeners only.

`-t` / `--top N` keeps the first N rows after sorting — and prints them, since a
quantity of answer only means something in output.

```console
$ swp --cpu --top 5
PORT    PID  USER    CPU   MEM  UP   NAME                        COMMAND
-     18966  dsaad  1.3%   26M  2s   mdworker_shared             -s mdworker -c MDSImporter…
-     66539  dsaad  1.0%  964M  54m  Code - Insiders Helper (R…  /Applications/Visual Studi…
-     83988  dsaad  0.4%  941M  3d   Google Chrome               /Applications/Google Chrom…
```

CPU is a **share of one core over a sampled interval**, the way `top` reports it,
so it exceeds 100% for a process using more than one. It cannot be read from a
single sample — macOS's `kinfo_proc.p_pctcpu` is hard zero on anything modern
and Linux publishes only a cumulative counter — so asking for it on the command
line costs a second sample, about a quarter of a second. The picker re-scans
every two seconds anyway, so there the column is free and always shown.

The alternative, total CPU time over the process's whole lifetime, needs one
sample but answers a different question: a tab that pinned a core last Tuesday
would outrank the one pinning it right now.

### A question answers; a browse opens the picker

`swp` with nothing to look for is a browse, and opens the list. `swp 3000` is a
question, and gets an answer on stdout:

```console
$ swp -p 3000
PORT    PID  USER   MEM  UP  NAME  COMMAND
3000  49649  dsaad  66M  1d  bun   --hot scripts/serve.ts
```

So a query works inside a pipeline, a script, `$( )` and a `Makefile` without
anyone reaching for a flag — which is the behaviour a command-line tool is
expected to have, and the reason `-l` is almost never needed. `-i` asks for the
picker anyway, for when the query is a starting point rather than the whole
question: `swp -i node` opens the list already narrowed, ready for another
keystroke.

Filters are not a query. `--me`, `-u` and `-a` narrow a browse rather than
naming a target, so they still open the picker.

### The query

A bare number is a **port**; above 65535 it can only be a **process id**, so it
is taken as one. Any other word is matched against the program name, then its
full command line, then the user. Extra words narrow — `swp node 3000` is the
node process on 3000, not everything called node plus everything on 3000.

When any process matches **by name**, the ones that matched only because their
command line mentions the word are dropped. On a machine running VS Code,
`swp node` otherwise returns the one node server plus six helpers whose
arguments contain `node.mojom` — and this is a query that can end in `--kill`,
so a near-miss is worse than no match. The looser reading is still there when
nothing matches by name, which is what makes `swp mojom` find them.

The ports-only default is what keeps the unfiltered list to two dozen readable
rows. It never narrows a *search*: naming a program or a `--pid` implies `-a`,
because hiding the thing you asked for because it holds no port would be
perverse.

### In the picker

| key | what it does |
| --- | --- |
| `↑` `↓` / `j` `k` | move — `g` / `G` first and last, PgUp / PgDn by a page |
| `/` | filter, fuzzily, across every column at once |
| `Enter` or `x` | send the default signal (asks first) |
| `X` | send `SIGKILL` (asks first) |
| `a` | every process / only the ones holding a port |
| `m` | only mine / every user |
| `s` | change the sort order |
| `r` | re-scan now — it also re-scans every 2 s |
| `y` | copy the pid (OSC 52, so it works over SSH) |
| `?` | the key reference |
| `q` / `Esc` | leave the filter, then clear it, then quit |

`j`/`k` move and `x` kills — deliberately never the other way round. A tool
that kills on the twin of the up-arrow is a tool that will one day kill the
wrong thing.

Killing always asks, whatever `--yes` says on the command line: there the
target was typed and can be read back before you press return, and here it is
wherever a cursor happens to be sitting. Only `y` and `Enter` confirm — every
other key cancels, so a stray keystroke can only ever be the safe answer.

### Flags

```
  -p, --port N       Match port N (repeatable)
  -n, --name TEXT    Match TEXT in the name or command (repeatable)
      --pid N        Match process id N (repeatable)
  -u, --user NAME    Only this user's processes (name or uid)
      --me           Only your own processes
  -a, --all          Include processes that hold no port
  -l, --list         Print the matches and exit — never open the picker
  -i, --pick         Open the picker even though a query was given
  -k, --kill         Signal the matches and exit
  -s, --signal NAME  HUP, INT, QUIT, KILL, TERM, STOP, CONT, USR1, USR2
  -9                 Shorthand for --signal KILL
  -y, --yes          Do not ask before signalling
      --cpu          Busiest first, across every process (= --sort cpu -a)
      --ram          Largest first, across every process (= --sort memory -a)
  -t, --top N        Keep only the first N rows, and print them
      --sort ORDER   port, pid, name, cpu, memory, started (default: port)
      --json         Machine-readable listing (implies --list)
      --width N      Output width (default: auto-detect)
      --theme NAME   dark, light, mono
      --no-color     Disable ANSI colours (also honours NO_COLOR)
```

Exit code is `0` when something matched (and every signal landed), `1` when
nothing matched or a signal failed — so `swp 3000 >/dev/null || echo free`
works, and so does `kill $(swp --json 3000 | jq '.[].pid')` if you like doing
it the long way.

### Redirected output

With stdout or stdin redirected there is no keyboard UI to run, so even a bare
`swp | grep` prints the listing instead of opening the picker — as does `-i`. Colour turns itself off in a
pipe, trailing padding is trimmed, and nothing is truncated — `swp -l -a` is
meant to be piped into things.

## What it can't see

### Other users' processes

On macOS the kernel will not open another user's file descriptors without root,
so **the ports, memory and CPU of other users' processes are invisible** — their
rows are there, those columns are not. `sudo swp` sees everything. The picker
says so in its footer rather than leaving you to wonder why `sudo lsof`
disagrees. On this machine that is 204 processes refused against 887 readable.

### Network and GPU, at all

There is no per-process **network** or **GPU** figure available to a program
like this, on either platform, and `swp --net` / `swp --gpu` say so rather than
failing as unknown options:

- **Network.** macOS publishes per-process bytes only through
  `NetworkStatistics.framework`, which is private API — it is what `nettop` and
  Activity Monitor use. Linux has no per-process byte counter at all;
  `/proc/<pid>/net/dev` is per network *namespace*, not per process, so tools
  like `nethogs` capture packets and attribute them by socket inode, which
  needs root.
- **GPU.** Activity Monitor reads per-process GPU through private
  `IOAccelerator` accounting. The public IOKit registry reports per-*device*
  utilisation only. On Linux it exists per vendor — NVML, and NVIDIA only.

Shipping either would mean a private framework, a packet capture running as
root, or a number that looks right and isn't. `swp` still tells you which ports
a process holds, which is usually the network question actually being asked.

The same call that would refuse those descriptors also refuses `proc_pidinfo`
for the process itself, which is why enumeration goes through
`sysctl(KERN_PROC_ALL)` — the table `ps` reads. The libproc route looks tidier
and quietly loses a third of the machine.

## How it works

| | macOS | Linux |
| --- | --- | --- |
| processes | `sysctl(KERN_PROC_ALL)`, then `libproc` for path and memory | `/proc/<pid>/{stat,status,cmdline,exe}` |
| arguments | `sysctl(KERN_PROCARGS2)` | `/proc/<pid>/cmdline` |
| sockets | `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` per fd | `/proc/net/tcp{,6}` and `udp{,6}`, joined to pids by socket inode |

Only **bound local** endpoints are collected — a TCP socket in `LISTEN`, or a
UDP socket with a local port. Established connections are left out: "who has
3000?" means the server, not the dozen browser sockets talking to it.

The environment is never read, though `KERN_PROCARGS2` hands it over right
after the arguments. Environments hold tokens and passwords, and this tool
prints what it reads.

## Development

```sh
just build            # swift build
just test             # swift test
just integration      # drive the built binary from bash
just check            # format-check + lint + test, the way CI does
just format           # swiftformat, in place
just lint-fix         # swiftlint --fix, then format
```

`swpCore` is everything that can be reasoned about without a terminal — the
scanners, the query language, formatting, the killer — and has no dependency on
the executable, so it is testable on its own. `swp` is the terminal: raw mode,
key decoding, the frame, the picker.

Frames are built by a pure function of state and size, which is what lets the
tests assert on a whole rendered frame rather than on the pieces that make one.

## Prior art, and a sibling

`lsof -i :3000` answers the same question and takes longer to start than this
takes to run. `fkill` and `fuser` are close cousins.

The chrome — the rounded frame, the wordmark, the fuzzy filter box — is
deliberately the same shape as [termdown](https://github.com/dsaad68/termdown),
in a different palette: teal → amber rather than blue → mauve, so that the
half-second of "which one did I just launch" never happens.

## License

MIT © 2026 Daniel Saad
