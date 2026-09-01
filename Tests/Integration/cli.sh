#!/usr/bin/env bash
# End-to-end checks against a built binary: the paths that only exist once the
# program is a process — exit codes, redirected output, and the two flags that
# make it act on something.
#
#   ./Tests/Integration/cli.sh .build/debug/swp
set -uo pipefail

BIN="${1:-.build/debug/swp}"
if [ ! -x "$BIN" ]; then
  echo "usage: $0 <path-to-swp>" >&2
  exit 2
fi

pass=0
fail=0

check() { # check <description> <expected-exit> <command…>
  local description="$1" expected="$2"
  shift 2
  local output status
  output="$("$@" 2>&1)"
  status=$?
  if [ "$status" -eq "$expected" ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$description"
  else
    fail=$((fail + 1))
    printf '  FAIL %s (exit %d, wanted %d)\n' "$description" "$status" "$expected"
    printf '%s\n' "$output" | head -3 | sed 's/^/       /' 
  fi
}

contains() { # contains <description> <needle> <command…>
  local description="$1" needle="$2"
  shift 2
  local output
  output="$("$@" 2>&1)"
  # A shell test rather than `printf … | grep -q`: grep exits on its first match
  # and closes the pipe, printf takes SIGPIPE, and `pipefail` then reports the
  # whole pipeline as failed — so every needle found early in a long listing
  # read as "not found".
  if [ "${output#*"$needle"}" != "$output" ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$description"
  else
    fail=$((fail + 1))
    printf '  FAIL %s (no "%s" in output)\n' "$description" "$needle"
    printf '%s\n' "$output" | head -3 | sed 's/^/       /' 
  fi
}

echo "swp integration checks ($BIN)"

# ── The basics ──
check    "--version exits 0"            0 "$BIN" --version
contains "--version names the tool"     "swp " "$BIN" --version
check    "--help exits 0"               0 "$BIN" --help
contains "--help documents --kill"      "--kill" "$BIN" --help
check    "an unknown flag exits 1"      1 "$BIN" --nope
contains "an unknown flag is named"     "unknown option" "$BIN" --nope
check    "a bad signal exits 1"         1 "$BIN" -k --signal BANANA 1
check    "a bad sort exits 1"           1 "$BIN" --sort sideways

# ── Redirected: the picker must fall back to a listing, never block on a key ──
# A timeout is the real assertion here: a keyboard UI that opened on a pipe
# would hang forever, and that is exactly the bug this checks for.
run_with_timeout() { # run_with_timeout <seconds> <command…>
  local limit="$1"; shift
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# `-i` asks for the picker; redirected, it must still fall back to printing
# rather than blocking on a key that cannot arrive.
if run_with_timeout 10 "$BIN" -i 65533; then
  pass=$((pass + 1)); printf '  ok   -i redirected falls back to printing\n'
else
  status=$?
  if [ "$status" -eq 124 ]; then
    fail=$((fail + 1)); printf '  FAIL -i hung on a pipe\n'
  else
    pass=$((pass + 1)); printf '  ok   -i redirected exits (%d)\n' "$status"
  fi
fi

if run_with_timeout 10 "$BIN" -a; then
  pass=$((pass + 1)); printf '  ok   a redirected bare run lists instead of paging\n'
else
  status=$?
  if [ "$status" -eq 124 ]; then
    fail=$((fail + 1)); printf '  FAIL a redirected bare run hung waiting for a key\n'
  else
    pass=$((pass + 1)); printf '  ok   a redirected bare run exits (%d)\n' "$status"
  fi
fi

contains "-l lists with a header"       "PORT" "$BIN" -l -a
# A query answers and exits, with no flag at all — the headless behaviour that
# makes swp usable from a script.
contains "a bare query prints a header"  "PORT" "$BIN" -a bash
check    "a bare query exits 0"          0 "$BIN" -a bash
contains "--json emits an array"        "\"pid\"" "$BIN" --json -a --me
check    "a port nobody holds exits 1"  1 "$BIN" -l 65533

# ── Acting on something we own, and nothing else ──
# A sleep of our own is the only safe target: it is ours, it is disposable, and
# its pid is known exactly.
sleep 30 &
victim=$!
sleep 1
contains "finds a process by pid"       "$victim" "$BIN" -l -a --pid "$victim"
check    "kills it with --yes"          0 "$BIN" -k -y --pid "$victim"
sleep 1
if kill -0 "$victim" 2>/dev/null; then
  fail=$((fail + 1)); printf '  FAIL the target survived --kill\n'
  kill -9 "$victim" 2>/dev/null
else
  pass=$((pass + 1)); printf '  ok   the target is gone\n'
fi
wait "$victim" 2>/dev/null

# ── The guards ──
check    "refuses to signal pid 1"      1 "$BIN" -k -y --pid 1
contains "says why it refused"          "pid 1" "$BIN" -k -y --pid 1

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
