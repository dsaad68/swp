# The swp guide

A complete tour, organised by what you are trying to do. If you only read one
section, read [the two modes](#1-the-two-modes) — everything else follows from
it.

- [1. The two modes](#1-the-two-modes)
- [2. Finding things](#2-finding-things)
- [3. Reading the output](#3-reading-the-output)
- [4. The picker](#4-the-picker)
- [5. Killing things](#5-killing-things)
- [6. CPU, memory and `--top`](#6-cpu-memory-and---top)
- [7. Scripting](#7-scripting)
- [8. What swp can't see](#8-what-swp-cant-see)
- [9. How it works](#9-how-it-works)
- [10. Troubleshooting](#10-troubleshooting)
- [Flag reference](#flag-reference)

Releasing swp is a separate document: [releasing.md](releasing.md).

---

## 1. The two modes

**A query answers and exits. A bare `swp` opens the picker.**

```console
$ swp 3000                    # a question — prints, exits
PORT    PID  USER   MEM  UP  NAME  COMMAND
3000  49649  dsaad  66M  1d  bun   --hot scripts/serve.ts

$ swp                         # a browse — opens the picker
```

That is the whole rule. It is what lets a query work inside a pipeline, a
script, `$( )` or a Makefile without anyone reaching for a flag, while `swp`
alone is still an interactive tool.

A **query** is a port, a pid, or a name — something that names a target. A
**filter** (`--me`, `-u`, `-a`) narrows a browse without naming anything, so
filters still open the picker:

| you type | you get |
| --- | --- |
| `swp` | picker, listening processes |
| `swp -a` | picker, every process |
| `swp --me` | picker, your listening processes |
| `swp 3000` | printed answer |
| `swp node` | printed answer |
| `swp -i 3000` | picker, opened on port 3000 |
| `swp -l` | printed listing of the browse |

Two overrides exist for when you want the other thing: **`-i` / `--pick`**
opens the picker despite a query, and **`-l` / `--list`** prints despite there
being none.

> **Redirection wins over all of it.** With stdout or stdin not a terminal there
> is no keyboard UI to run, so even `swp -i` prints. `swp | grep` does the
> obvious thing instead of painting a frame into a pipe or blocking on a key
> that cannot arrive.

---

## 2. Finding things

### The query language

- **A bare number is a port.** `swp 3000`.
- **Above 65535 it can only be a pid**, so it is taken as one. `swp 41235`.
- **Anything else is text**, matched against the program name, then its full
  command line, then the user.
- **Extra words narrow.** `swp node 3000` is the node process on 3000 — not
  everything called node plus everything on 3000.

Be explicit when you need to be: `-p/--port`, `--pid`, `-n/--name`. All three
repeat, and repeats of one kind are an OR:

```sh
swp -p 3000 -p 8080      # either port
swp -n node -p 3000      # named node AND on 3000
swp --pid 4123           # this exact process
```

### Name matches win outright

When anything matches a term **by name**, the processes that matched only
because their *command line* mentions it are dropped entirely — not ranked
lower.

On a machine running VS Code, `swp node` would otherwise return the one node
server plus six helpers whose arguments contain `node.mojom`. This is a query
that can end in `--kill`, so a near-miss is worse than no match.

The looser reading is still there when nothing matches by name, which is what
makes `swp mojom` find those helpers.

### Ports-only is the browse default, never a search

`swp` with nothing named shows only processes holding a port — that is what
keeps the list to two dozen readable rows. It never narrows a search:

- naming a program or a `--pid` implies `-a`
- `--cpu` and `--ram` imply `-a` (see [§6](#6-cpu-memory-and---top))

Hiding the thing you asked for because it holds no port would be perverse.

### Narrowing by user

```sh
swp --me            # only yours
swp -u root         # by name or uid
swp -a -u _spotlight
```

---

## 3. Reading the output

```
PORT           PID  USER    CPU   MEM  UP   NAME       COMMAND
3000         49649  dsaad  0.1%   66M  1d   bun        --hot scripts/serve.ts
5353,50224+3 14182  dsaad    0%  169M  1d   Chrome He… --type=utility --utilit…
-             1588  root       -    -  4d   logd       /usr/libexec/logd
```

| column | meaning |
| --- | --- |
| **PORT** | Bound local ports. `5353,50224+3` means two shown, three more. `-` means none. |
| **PID** | Process id. |
| **USER** | Owner's login name, or the numeric uid when there is no passwd entry. |
| **CPU** | Share of **one core** over a sampled interval — over 100% is real. Shown only when measured; see [§6](#6-cpu-memory-and---top). |
| **MEM** | Resident set size. |
| **UP** | How long it has been running, to one unit. |
| **NAME** | The executable's own name. |
| **COMMAND** | The arguments after `argv[0]`. |

Three things the columns do deliberately:

- **A dash is not a zero.** `-` means the kernel would not say. An idle process
  shows `0%`; one whose CPU was refused shows `-`. They sort differently too —
  unknowns go last under `--cpu`, because an unknown is not the answer to "what
  is eating my CPU".
- **A wildcard port is coloured differently** from a loopback one. `*:3000` is
  reachable from another machine; `127.0.0.1:3000` is not.
- **`COMMAND` drops `argv[0]` when it only repeats NAME**, so you get
  `--hot serve.ts` rather than `bun --hot serve.ts`. It is *kept* when it says
  something different — a process that rewrote its own argv is telling you what
  it thinks it is, and `Raycast Backend` against the name `node` is the whole
  answer to why node is holding a port.

Colour turns itself off in a pipe, on `--no-color`, and on `NO_COLOR`. Trailing
padding is trimmed, and nothing is truncated when redirected — `swp -l -a` is
meant to be piped.

---

## 4. The picker

| key | what it does |
| --- | --- |
| `↑` `↓` or `j` `k` | move the cursor |
| `g` / `G` | first / last |
| `PgUp` / `PgDn` | by a page |
| Click | select a row — **never acts** |
| `/` | focus the filter |
| `Backspace` | delete a character, then leave the box |
| `Esc` | leave the box, then clear it, then quit |
| `a` | every process / only port-holders |
| `m` | only mine / every user |
| `s` | sort: port → pid → name → cpu → memory → started |
| `r` | rescan now (it also rescans every 2 s) |
| `Enter` or `x` | send the default signal — **asks first** |
| `X` | send `SIGKILL` — **asks first** |
| `y` | copy the pid (OSC 52, so it works over SSH) |
| `?` | the key reference |
| `q` | quit |

### The filter

`/` filters **fuzzily across every column at once** — name, port, pid, user and
command are all one searchable string, so `3000`, `bun`, `dsa` and `serve` all
work. Matched characters are highlighted in the row.

Filtering is modal: while the box is focused every printable key types into it,
so a query may contain `q`, `x` and `a` like any other letter. That is also why
the letter that kills cannot be typed by accident while searching.

### Things the picker does so you don't have to think about them

- **It follows the cursor by pid, not by index.** A process exiting above the
  cursor cannot slide a different row underneath it between your keystroke and
  the signal.
- **Columns hold still while you type.** They are sized over every row, not the
  matching ones, so the table does not re-flow on each keystroke.
- **Equal rows keep their order** across refreshes — every sort breaks ties on
  pid, so nothing swaps places under the cursor.
- **Short terminals get a compact header.** Under 22 rows the wordmark is
  dropped rather than leaving three rows of list.

---

## 5. Killing things

### From the picker

`Enter` or `x` sends the default signal, `X` sends `SIGKILL`. Both open a
confirmation naming the process three ways — what it is, what it is running,
and what it holds — because the one thing a confirmation must prevent is
agreeing to kill a row you misread.

**Only `y` and `Enter` confirm. Every other key cancels**, so a stray keystroke
can only ever be the safe answer. The picker always asks, whatever `--yes` says
on the command line: there you typed the target and can read it back before
pressing return, here it is wherever a cursor happens to be sitting.

### From the command line

```sh
swp -k 3000                # asks, listing every target first
swp -k -y 3000             # don't ask
swp -k -9 node             # SIGKILL
swp -k -s HUP --pid 4123   # any signal by name or number
```

`-k` signals **every** match, so read the query first. Without `--yes` it names
each target and asks once. With stdin redirected there is nobody to ask, so it
stops and tells you which flag would have let it proceed rather than acting
unasked.

### Signals

`HUP`, `INT`, `QUIT`, `KILL`, `TERM`, `STOP`, `CONT`, `USR1`, `USR2`. Spell them
any way you like: `TERM`, `SIGTERM`, `term`, `15`. Default is `TERM`.

**`TERM` asks a process to shut down and lets it** — flush buffers, close its
port, tell its children. `KILL` cannot be caught and therefore cannot clean up.
That is why `TERM` is the default and `KILL` is one keystroke away.

### It tells you what actually happened

A `TERM` that is caught and ignored looks identical to one that worked until you
check. `swp` waits up to two seconds and reports the truth:

```console
$ swp -k -y 3000
killed bun (pid 49649) with SIGTERM              # it's gone
signalled bun (pid 49649) with SIGTERM — still running    # it isn't
could not signal sshd (pid 412): operation not permitted — try again with sudo
```

### The guards

- **pid 1 is refused outright**, as is any non-positive pid. `kill(0, …)` signals
  your whole process group and `kill(-1, …)` every process you own; either would
  turn a mistyped pid into a logout.
- **`j`/`k` move, `x` kills.** Never the other way round.
- **A click selects, never acts.** The mouse is the one input with no
  confirmation habit attached to it.

---

## 6. CPU, memory and `--top`

```sh
swp --cpu --top 5     # the five busiest processes
swp --ram -t 10       # the ten largest by memory
```

Both shorthands **imply `-a`**: "what is eating my CPU" is a question about the
machine, not about its listeners, and answering it from among the processes that
happen to hold a port would be a strange reading. `--sort cpu` stays a pure sort
modifier if you did mean it about listeners only.

`-t` / `--top N` keeps the first N rows **after** sorting and filtering — so
`swp --cpu --top 5 node` is the five busiest *node* processes — and it **implies
printing**, since a quantity of answer only means something in output.

### What the CPU number means

**A share of one core over a sampled interval**, the way `top` reports it. A
process using two cores shows ~200%.

It cannot be read from a single sample. macOS's `kinfo_proc.p_pctcpu` is hard
zero on anything modern, and Linux publishes only a counter of total CPU time
consumed since the process started. A rate has to be *measured*: take that
counter twice and divide the difference by the wall time between readings.

So:

- **On the command line**, asking for CPU costs a second sample — about a
  quarter of a second. It is taken only when asked, which is why `swp -p 3000`
  still answers in 30 ms and shows no CPU column.
- **In the picker** the column is free and always shown, because it rescans
  every two seconds anyway. The first refresh is brought forward to 0.25 s so
  the numbers arrive promptly rather than after a full interval.

The alternative — total CPU time over a process's whole lifetime — needs one
sample but answers a different question. A browser tab that pinned a core last
Tuesday would outrank the one pinning it right now.

The sampler checks each pid's **start time** before differencing. pids get
reused, and subtracting a dead process's counter from the live one wearing its
number reports a wild spike or a negative.

---

## 7. Scripting

### Exit codes

`0` when something matched and every signal landed. `1` when nothing matched, a
signal failed, or the arguments were wrong.

```sh
swp -p 3000 >/dev/null 2>&1 || echo "3000 is free"

# wait for a server to come up
until swp -p 3000 >/dev/null 2>&1; do sleep 0.2; done

# is this pid still around?
if swp --pid "$pid" >/dev/null 2>&1; then echo "still running"; fi
```

There is no `--quiet`; redirect both streams, since the "nothing matched"
explanation goes to stderr.

### JSON

`--json` implies `--list` and emits an array, keys sorted:

```console
$ swp --json 3000
[
  {
    "arguments" : [ "bun", "--hot", "serve.ts" ],
    "command" : "bun --hot serve.ts",
    "listeners" : [
      { "address" : "*", "family" : "v4", "port" : 3000, "protocol" : "tcp" }
    ],
    "memory_bytes" : 60112896,
    "name" : "bun",
    "path" : "/opt/homebrew/Cellar/bun/1.4.0/bin/bun",
    "pid" : 14322,
    "ppid" : 14320,
    "started" : "2026-08-30T22:39:11Z",
    "uid" : 501,
    "user" : "dsaad"
  }
]
```

`cpu_percent` and `cpu_seconds` appear **only when a rate was measured**
(`--cpu` / `--sort cpu`). A key that is sometimes a number and sometimes a
zero-meaning-unknown is worse than an absent one, and `jq` can ask whether it is
there. Slashes are unescaped, because paths are the most common field here.

```sh
swp --json 3000 | jq '.[].pid'
swp --json --cpu --top 5 | jq -r '.[] | "\(.cpu_percent | floor)%\t\(.name)"'
swp --json -a | jq '[.[] | select(.listeners | length > 0)] | length'
```

### Recipes

```sh
# free a port before starting something
port-free() { swp -k -y -p "$1" 2>/dev/null; }

# what did I leave running?
alias ports='swp -l'

# the biggest thing on the machine, name only
swp --json --ram -t 1 | jq -r '.[0].name'
```

### Width

Redirected output is not truncated at all — the last column gets whatever it
needs. Force a width with `--width N` when you want columns to line up in a file.

---

## 8. What swp can't see

### Other users' processes

Without root, macOS will not open another user's file descriptors, so **their
ports, memory and CPU are invisible**. The rows are there; those columns are
not. On a typical machine that is around 200 processes refused against 900
readable.

`sudo swp` sees everything. The picker says so in its footer rather than leaving
you to wonder why `sudo lsof` disagrees.

This is also why enumeration goes through `sysctl(KERN_PROC_ALL)` — the table
`ps` reads — rather than the tidier-looking `proc_listpids` + `proc_pidinfo`
route, which returns `EPERM` per process and quietly loses a third of the
machine with no error anywhere.

### Network and GPU, at all

There is no per-process figure for either that a program like this can obtain.
`swp --net` and `swp --gpu` say so rather than failing as unknown options.

**Network.** macOS publishes per-process bytes only through
`NetworkStatistics.framework`, which is private API — it is what `nettop` and
Activity Monitor use. Linux has no per-process byte counter at all;
`/proc/<pid>/net/dev` is per network *namespace*, not per process, which is why
`nethogs` captures packets and attributes them by socket inode, needing root.

**GPU.** Activity Monitor reads per-process GPU through private `IOAccelerator`
accounting. The public IOKit registry reports per-*device* utilisation only. On
Linux it exists per vendor — NVML, and NVIDIA only.

Shipping either would mean a private framework, a packet capture running as
root, or a number that looks right and isn't. `swp` still tells you which ports
a process holds, which is usually the network question actually being asked.

### Established connections

Only **bound local** endpoints are collected — a TCP socket in `LISTEN`, or a
UDP socket with a local port. "Who has 3000?" means the server, not the dozen
browser sockets talking to it, and listing every one of those would bury the row
worth acting on.

### The environment

Never read, though `KERN_PROCARGS2` hands it over right after the arguments.
Environments hold tokens and passwords, and this tool prints what it reads.

---

## 9. How it works

| | macOS | Linux |
| --- | --- | --- |
| processes | `sysctl(KERN_PROC_ALL)`, then libproc for path and memory | `/proc/<pid>/{stat,status,cmdline,exe}` |
| arguments | `sysctl(KERN_PROCARGS2)` | `/proc/<pid>/cmdline` |
| CPU | `proc_taskinfo` — the same call already made for memory | `/proc/<pid>/stat` fields 14 and 15 |
| sockets | `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)` per fd | `/proc/net/tcp{,6}` and `udp{,6}`, joined to pids by socket inode |

The shapes are inverted: macOS asks the kernel per process and gets its sockets
back, while Linux publishes the socket table globally and makes you join it to
processes yourself through the inode behind each socket fd.

A full scan of ~1000 processes is about **12 ms**, which is what makes a
self-refreshing list affordable. Getting there took two fixes worth knowing
about if you read the source:

- `KERN_PROCARGS2` wants a buffer the size of `KERN_ARGMAX` — a megabyte on
  macOS. Allocating one per process turned a 12 ms scan into 600 ms. One reader
  owns one buffer for a whole scan.
- The picker used to re-sort an already-sorted list and re-render every row on
  each keystroke. Neither depends on the filter, so both moved to per-scan:
  11.4 ms → 4.6 ms per keystroke.

### Why no dependencies

`swp` has none, and `Package.resolved` does not exist. That is deliberate:
nothing to audit, nothing to pin, a clone that builds offline.

The question has been asked concretely — would one of `swift-collections`'
types help? Profiled, no. The two places one fits are `Listener.merged()`
(`OrderedDictionary`, 6 µs) and `portSummary()` (`OrderedSet`, 0.5 µs), against
a real per-keystroke cost of 4.6 ms. Six orders of magnitude apart.

If `swp` grows multi-select — killing several at once — `OrderedSet<Int32>` of
pids is exactly right and the dependency goes in without argument.

---

## 10. Troubleshooting

**"nothing is listening" but I know something is.** It probably belongs to
another user. Try `sudo swp`.

**A process shows in `swp -a` with no PORT.** Same reason, if it is not yours.
If it *is* yours, it genuinely holds no bound local port — an outbound
connection is not a listener.

**`swp node` doesn't find my node process.** It may be running under a different
executable name. Try `swp -a -n node`, or search the command line for something
distinctive: `swp server.js`.

**`swp` opened the picker when I wanted output.** You gave it a filter, not a
query — `--me` and `-a` narrow a browse. Add `-l`.

**`swp 3000` printed when I wanted the picker.** Use `-i 3000`.

**The CPU column is all dashes.** In one-shot mode it appears only with `--cpu`
or `--sort cpu`, since a rate costs a second sample. For other users' processes
it is refused entirely.

**A kill said "still running".** The process caught `SIGTERM` and ignored it.
`X` in the picker, or `-9` on the command line, sends `SIGKILL`, which cannot be
caught.

**The terminal is left in a strange state.** It shouldn't be — raw mode and the
alternate screen are restored via `atexit` and the fatal signal handlers. If it
happens, `reset` fixes it and it is a bug worth reporting.

---

## Flag reference

```
  -p, --port N       Match port N (repeatable)
  -n, --name TEXT    Match TEXT in the name or command (repeatable)
      --pid N        Match process id N (repeatable)
  -u, --user NAME    Only this user's processes (name or uid)
      --me           Only your own processes
  -a, --all          Include processes that hold no port. Implied whenever a
                     name or --pid is given: only a browse is narrowed
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
  -V, --version      Show version information
  -h, --help         Show this help
```

`--net` and `--gpu` are recognised and explain why they cannot be answered.
