#!/bin/sh
tmp="$1"; [ -f "$tmp/nethttp.pid" ] && kill "$(cat "$tmp/nethttp.pid")" 2>/dev/null
rm -f "$tmp/nethttp.pid"
exit 0
