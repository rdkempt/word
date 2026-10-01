#!/bin/sh
tmp="$1"; [ -f "$tmp/nethttps.pid" ] && kill "$(cat "$tmp/nethttps.pid")" 2>/dev/null
rm -f "$tmp/nethttps.pid" "$tmp/nb.key" "$tmp/nb.crt"
exit 0
