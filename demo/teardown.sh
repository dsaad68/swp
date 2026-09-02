#!/usr/bin/env bash
# Stop whatever setup.sh started, including any the demo did not kill itself.
here="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$here/.pids" ]; then
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$here/.pids"
  rm -f "$here/.pids"
fi
rm -rf "$here/.bin"
