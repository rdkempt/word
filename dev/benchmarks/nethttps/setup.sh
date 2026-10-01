#!/bin/sh
# Mint a throwaway certificate and start the local TLS server. $1 is a scratch
# dir. python3 and openssl are dev-only tools, as they are elsewhere.
tmp="$1"; here=$(cd "$(dirname "$0")" && pwd)
command -v python3 >/dev/null 2>&1 || exit 1
command -v openssl >/dev/null 2>&1 || exit 1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/nb.key" -out "$tmp/nb.crt" \
  -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" -sha256 >/dev/null 2>&1
[ -s "$tmp/nb.crt" ] || exit 1
python3 "$here/../netserve.py" 4492 "$tmp/nb.crt" "$tmp/nb.key" >/dev/null 2>&1 & echo $! > "$tmp/nethttps.pid"
sleep 2
exit 0
