#!/usr/bin/env bash
# Stand up disposable listeners for the demo.
#
# Two reasons this exists rather than the tape recording whatever happens to be
# on the machine: the recording is reproducible, and — more to the point — the
# tape ends by killing something, which must be something it created.
#
# The listeners are copies of one tiny compiled binary under three names,
# because macOS takes a process's NAME from its executable and NAME is the
# column the demo reads. `exec -a vite python3 …` still shows up as "Python".
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/.bin"
mkdir -p "$bin"
: > "$here/.pids"

if [ ! -x "$bin/listener" ]; then
  swiftc -O "$here/listener.swift" -o "$bin/listener" 2>/dev/null
fi

serve() { # serve <port> <name> [extra args…]
  local port="$1" name="$2"
  shift 2
  cp -f "$bin/listener" "$bin/$name"
  # The extra arguments are real — they are this process's actual argv, which
  # is what swp reads. They exist so the COMMAND column shows something that
  # reads like a server rather than a bare port number.
  "$bin/$name" "$@" --port "$port" &
  echo $! >> "$here/.pids"
}

serve 4200 dev-server --host 0.0.0.0
serve 5173 vite --host 127.0.0.1 --strictPort
serve 9229 api-gateway --inspect --cluster

# Give them a moment to bind, or the demo's first frame shows an empty list.
for _ in $(seq 30); do
  sleep 0.1
  bound=0
  for p in 4200 5173 9229; do
    (echo >"/dev/tcp/127.0.0.1/$p") 2>/dev/null && bound=$((bound + 1))
  done
  [ "$bound" -eq 3 ] && break
done
