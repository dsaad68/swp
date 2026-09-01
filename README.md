# swp

[![CI](https://github.com/dsaad68/swp/actions/workflows/ci.yml/badge.svg)](https://github.com/dsaad68/swp/actions/workflows/ci.yml)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux-blue)
![Swift](https://img.shields.io/badge/swift-5.9%2B-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Find what's holding a port, and kill it.**

```console
$ swp -p 3000
PORT    PID  USER   MEM  UP  NAME  COMMAND
3000  49649  dsaad  66M  1d  bun   --hot scripts/serve.ts
```

Written in pure Swift with no `lsof`, no `ps`, and no subprocesses — it reads
the kernel's own process and socket tables. A full scan of a thousand processes
takes about **12 ms**, which is what lets the picker refresh itself while you
look at it.

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
│ PORT           PID  USER    CPU   MEM  UP   NAME           COMMAND       │
│ 3000         49649  dsaad  0.1%   66M  1d   bun            --hot serve.… │
│ 5432          1120  dsaad  2.4%  212M  4d   postgres       -D /data      │
│ 8080         19074  dsaad    0%   12M  1d   sabacc-server  --addr 127.0… │
│ 11434         1588  dsaad    0%   27M  4d   ollama         serve         │
│ ↑↓ move · / filter · ⏎ SIGTERM · X SIGKILL · a all · s sort · ? keys     │
╰──────────────────────────────────────────────────────────────────────────╯
```

## Install

### Homebrew (macOS and Linux)

```sh
brew install dsaad68/tap/swp
```

Upgrade later with `brew upgrade swp`. The macOS bottle is a universal binary
(Apple Silicon and Intel); Linux is x86_64.

### From source

Requires a Swift 5.9+ toolchain.

```sh
git clone https://github.com/dsaad68/swp && cd swp
just install          # release build, symlinked into ~/.local/bin (no sudo)
```

Make sure `~/.local/bin` is on your `PATH`. To run from a clone without
installing: `just swp`, `just swp 3000`, `just swp -i node`.

## The six things you'll actually type

```sh
swp                   # browse everything holding a port
swp 3000              # print what's on port 3000
swp node              # print processes named — or running — node
swp -k 3000           # kill what's on 3000 (asks first)
swp --cpu --top 5     # the five busiest processes
swp -a                # browse every process, port or not
```

The rule that makes the rest predictable: **a query answers and exits, a bare
`swp` opens the picker.** So `swp 3000` prints and works in a pipeline with no
flag for it, while `swp` alone browses. `-i` opens the picker on a query
anyway.

## In the picker

| key | |
| --- | --- |
| `↑` `↓` / `j` `k` | move — `g` / `G` first and last |
| `/` | filter, fuzzily, across every column at once |
| `Enter` or `x` | send `SIGTERM` (asks first) |
| `X` | send `SIGKILL` (asks first) |
| `a` · `m` · `s` | all processes · only mine · change sort |
| `r` · `y` · `?` · `q` | rescan · copy pid · keys · quit |

`j`/`k` move and `x` kills — deliberately never the other way round. A tool that
kills on the twin of the up-arrow will one day kill the wrong thing.

## Documentation

**[The guide](docs/guide.md)** covers everything: the query language, every
flag, reading each column, killing safely, scripting with `--json`, and what
`swp` cannot see. **[Releasing](docs/releasing.md)** documents the tag-driven
pipeline. [CHANGELOG.md](CHANGELOG.md) tracks releases.

## Two honest limits

Without root, macOS will not open another user's file descriptors, so **the
ports, memory and CPU of other users' processes are invisible**. Their rows are
there; those columns are not. `sudo swp` sees everything, and the picker says so
in its footer rather than leaving you to wonder why `sudo lsof` disagrees.

There is **no per-process network or GPU figure** available to a program like
this on either platform — both need private frameworks or a root packet
capture. `swp --net` and `swp --gpu` explain that rather than failing as unknown
options. [Details in the guide.](docs/guide.md#what-swp-cant-see)

## Development

```sh
just build    just test    just integration
just check       # format + lint + test, the way CI does
just linux-test  # the same, for Linux, in a container (needs Docker)
just preflight   # both of the above — run this before tagging
```

swp's Linux scanner is behind `#if !canImport(Darwin)`, so a macOS build never
compiles it. Run `just linux-test` before releasing;
[docs/releasing.md](docs/releasing.md) explains why that is not hypothetical.

`swpCore` is everything reasonable without a terminal — the scanners, the query
language, formatting, the killer — and has no dependency on the executable, so
it is testable alone. `swp` is the terminal: raw mode, key decoding, frames, the
picker. Frames are a pure function of state and size, so tests assert on whole
rendered frames rather than on the pieces that make one.

There are no third-party dependencies, and that is deliberate — see
[the guide](docs/guide.md#why-no-dependencies).

## Prior art, and a sibling

`lsof -i :3000` answers the same question and takes longer to start than this
takes to run. `fkill` and `fuser` are close cousins.

The chrome — rounded frame, wordmark, fuzzy filter box — is deliberately the
same shape as [termdown](https://github.com/dsaad68/termdown), in a different
palette: teal → amber rather than blue → mauve, so the half-second of "which one
did I just launch" never happens.

## License

MIT © 2026 Daniel Saad
