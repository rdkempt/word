#!/bin/sh
# test_net_live.sh: the client against the real internet, one host after
# another.
#
# test_net.sh fetches one page and one large file, and test_tls_server.sh talks
# to a local openssl. Neither shows much of what a client meets: different TLS
# stacks, certificate chains and issuers, HTTP/1.1 bodies framed by
# Content-Length or chunked, bodies from a few hundred bytes to half a
# megabyte, and redirects with no body. This fetches a list of hosts and
# reports each one, like the interop suites other from-scratch TLS
# implementations keep.
#
# Read the results with the network in mind. On a normal network this reaches
# many independent servers. Behind a proxy that terminates TLS, every
# connection goes to the same gateway and every certificate comes from one
# issuer, so a green run there shows the HTTP and record layers work and says
# little about chains.
#
# It depends on the network, so one unreachable host mustn't fail it: the
# threshold is 80% of the hosts, which one outage won't cross and a systemic
# break will. CI runs it as informational.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export TMPDIR="$tmp"

cat > "$tmp/probe.w" <<'WEOF'
d = args()
if len(d) < 2
    out("usage: probe <host>")
else
    b = get(d[1])
    if b == none
        out("FAIL")
    else
        out("OK " . len(b))
WEOF
"$WORD" build "$tmp/probe.w" -o "$tmp/probe" >/dev/null 2>&1 || {
  echo "FAIL: could not build the probe"; exit 1; }

HOSTS="example.com
www.google.com
cloudflare.com
github.com
wikipedia.org
en.wikipedia.org
www.rust-lang.org
ziglang.org
www.debian.org
www.kernel.org
news.ycombinator.com
www.openbsd.org"

total=0; okc=0; failed=""
echo "live HTTPS across independent hosts:"
for h in $HOSTS; do
  total=$((total + 1))
  got=$(timeout 45 "$tmp/probe" "$h" 2>/dev/null | tail -1)
  case "$got" in
    "OK "*)
      n=${got#OK }
      if [ "$n" = "0" ]; then echo "  ok:   $h (verified; empty body, a redirect)"
      else echo "  ok:   $h ($n bytes)"; fi
      okc=$((okc + 1)) ;;
    *)
      echo "  FAIL: $h (no body: DNS, TCP, handshake, or certificate verification)"
      failed="$failed $h" ;;
  esac
done

echo
echo "test_net_live: $okc/$total hosts"
[ -n "$failed" ] && echo "  did not complete:$failed"
# 80% of the list, rounded down: one outage passes, a systemic break doesn't.
need=$(( total * 8 / 10 ))
if [ "$okc" -lt "$need" ]; then
  echo "  below the $need/$total threshold, treating as a failure"
  exit 1
fi
exit 0
