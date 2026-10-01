#!/bin/sh
# Start the local HTTP server the benchmark fetches from. $1 is a scratch dir.
tmp="$1"; here=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null 2>&1 || exit 1
python3 "$here/../netserve.py" 4491 >/dev/null 2>&1 & echo $! > "$tmp/nethttp.pid"
i=0
while [ $i -lt 40 ]; do
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null "http://127.0.0.1:4491/p" && exit 0
  else
    sleep 1; exit 0
  fi
  i=$((i+1)); sleep 0.1
done
exit 1
