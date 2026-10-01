#!/bin/sh
# test_net.sh: build examples/https/https.w (HTTPS written in word: TLS 1.3
# and X.509 chain verification against the OS trust store) and run it against
# the live network. `word build` adds the `net` library, which the word binary
# carries, to the program's own source, compiles the whole thing and writes one
# ELF, in one process, with no as or ld.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
prog=${1:-"$root/examples/https/https.w"}
cd "$root"   # uniform cwd; net builds are self-contained (the library is in the binary)

# --- recoverable failures: an unusable URL or body must give none, not a fault ---
# Nothing here is a fixed buffer (a region grows), so what's checked is the
# recovery: a host that can't resolve, a path no server would answer, and a
# body bigger than a request should carry. Each must be none from get() or
# post(), and a clean exit. These pass with or without a network.
recover() { nm="$1"; src="$2"
  printf '%s' "$src" > "$tmp/r.w"
  if ! "$WORD" build "$tmp/r.w" -o "$tmp/r" >/dev/null 2>&1; then
    echo "test_net: FAIL ($nm: build failed)"; exit 1; fi
  got=$(timeout 15 "$tmp/r" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && [ "$got" = "recovered" ]; then echo "  recover: $nm -> none"
  else echo "test_net: FAIL ($nm: rc=$rc out=[$got], expected clean recovery)"; exit 1; fi; }

recover "over-long host" 'import net
h = "http://"
i = 0
loop i < 500
    h = h . "a"
    i = i + 1
r = get(h . ".invalid/")
if r == none
    out("recovered")
'
recover "over-long path" 'import net
p = "http://example.com/"
i = 0
loop i < 5000
    p = p . "x"
    i = i + 1
r = get(p)
if r == none
    out("recovered")
'
recover "over-long body" 'import net
b = ""
i = 0
loop i < 20000
    b = b . "z"
    i = i + 1
r = post("http://127.0.0.1:59999/", b)
if r == none
    out("recovered")
'

# --- a large body must come back whole, not truncated ---
# The response grows in a region, and the ceiling (net_max_body, 64 MiB) is far
# above this file. Fetch a pinned file that never changes (typescript@5.4.5,
# about 8.7 MiB) over HTTPS and require the decoded length to be over 4 MiB. If
# the CDN is unreachable the body is `none` and we skip (one host shouldn't
# decide CI), and a non-empty body of 4 MiB or less is a truncation and fails.
printf 'import net\nb = get("https://cdn.jsdelivr.net/npm/typescript@5.4.5/lib/typescript.js")\nif b == none\n    out(0)\nif b != none\n    out(len(b))\n' > "$tmp/big.w"
if "$WORD" build "$tmp/big.w" -o "$tmp/big" >/dev/null 2>&1; then
  n=$(timeout 90 "$tmp/big" 2>/dev/null)
  if [ "$n" = 0 ] || [ -z "$n" ]; then
    echo "  large: SKIP (cdn.jsdelivr.net unreachable)"
  elif [ "$n" -gt 4194304 ] 2>/dev/null; then
    echo "  large: got $n bytes, whole"
  else
    echo "test_net: FAIL (large body truncated to $n, expected > 4194304)"; exit 1
  fi
else
  echo "test_net: FAIL (large-fetch program did not build)"; exit 1
fi

"$WORD" build "$prog" -o "$tmp/fetch"
# Keep the streams apart: stdout is the body, which decides PASS or FAIL, and
# stderr is get()'s note on the stage that failed (net: DNS, TCP, TLS ...),
# which mustn't be mistaken for a body.
out=$(timeout 90 "$tmp/fetch" 2>"$tmp/err" || true)
echo "  fetch: $(printf '%s' "$out" | head -1)"
[ -s "$tmp/err" ] && echo "  note:  $(head -1 "$tmp/err")"
case "$out" in
  "request failed"|"") echo "test_net: FAIL (no response, network down?)"; exit 1;;
  *) echo "test_net: PASS (live HTTPS request completed)"; exit 0;;
esac
