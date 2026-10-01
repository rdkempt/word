#!/bin/sh
# test_net_verbs.sh: the parts of `net` (SPEC 12.2) that other suites don't
# cover.
#
#   1. put(), delete() and head(). Only get() and post() used to have tests.
#      head() succeeds with an empty region and a failure is none, and telling
#      those apart is how every verb reports failure.
#   2. The `insecure` argument, the one argument in the language that turns off
#      a security check. The case that matters most is that leaving it out keeps
#      verification on.
#   3. A server that asks for a client certificate (the last section). Every
#      fetch used to wait out the 30 s idle deadline there, then answer none with
#      nothing on stderr.
#
# Everything runs against 127.0.0.1, so this needs no root, no changes to the
# trust store and no external network. python3 (the echo server) and openssl
# (throwaway certificates) are test tools only; nothing needs them to build or
# run word.
#
# No `set -e`: several cases expect a failed request.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
# Git Bash's own path rewriting is off too, because a subject looks like a path
# to it: `-subj /CN=127.0.0.1` reached openssl.exe as
# `C:/Program Files/Git/CN=127.0.0.1`, so no certificate was made and none of
# the https:// cases below ran. Every path this script hands a native program
# is converted explicitly instead, as in test_x509_profile.sh. On Linux and
# macOS these variables do nothing.
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
WORD=$(wordbin "${WORD:-$root/word}")
cd "$root"          # uniform cwd; net builds are self-contained (the library is in the binary)
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(hostpath "$(mktemp -d)"); pass=0; fail=0
cleanup() {
  for f in "$tmp/http.pid" "$tmp/tls.pid" "$tmp/cr.pid"; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }

# run <name> <expected-stdout> ; program on stdin. A 30 s cap turns a hang into
# a reported failure instead of a stuck suite.
run() { cat > "$tmp/p.w"; nm="$1"; want="$2"
  if ! "$WORD" build "$tmp/p.w" -o "$tmp/p" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  got=$(timeout 30 "$tmp/p" 2>"$tmp/err"); rc=$?
  if [ "$rc" = 124 ]; then bad "$nm" "timed out after 30 s (no response and no recovery)"; return; fi
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm"
  else bad "$nm" "got [$got] rc=$rc want [$want]$( [ -s "$tmp/err" ] && printf '; stderr: %s' "$(head -1 "$tmp/err")")"; fi; }

# The echo server reports the method it saw and how many body bytes it read, so
# post() and put() are checked for sending the body, not just for returning
# something. One handler serves both plain HTTP and TLS.
cat > "$tmp/echo.py" <<'PY'
import ssl, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
BIG = ("w\u00f6rd-\u00fcn\u00efcode-payload-" * 3200).encode()   # 67200 code points, 76800 bytes
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def reply(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(n) if n else b''
        if self.path == '/big':
            payload = BIG
        else:
            payload = ("METHOD=%s len=%d" % (self.command, len(body))).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        if self.command != 'HEAD':      # a HEAD reply carries headers only
            self.wfile.write(payload)
    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = reply
    def log_message(self, *a): pass
srv = HTTPServer(('127.0.0.1', int(sys.argv[1])), H)
if len(sys.argv) > 2:                   # cert + key -> serve TLS
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(sys.argv[2], sys.argv[3])
    srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
srv.serve_forever()
PY

# ---------------------------------------------------------------------------
echo "== every HTTP verb, over plain http:// =="
if ! command -v python3 >/dev/null 2>&1; then
  echo "  SKIP: no python3 for the echo server"
else
python3 "$tmp/echo.py" 4481 >/dev/null 2>&1 & echo $! > "$tmp/http.pid"
sleep 2

run "get() sends GET and returns the body" "METHOD=GET len=0" <<'EOF'
import net
out(get("http://127.0.0.1:4481/x"))
EOF
run "post() sends POST and its body" "METHOD=POST len=5" <<'EOF'
import net
out(post("http://127.0.0.1:4481/x", "hello"))
EOF
run "put() sends PUT and its body" "METHOD=PUT len=3" <<'EOF'
import net
out(put("http://127.0.0.1:4481/x", "abc"))
EOF
run "delete() sends DELETE" "METHOD=DELETE len=0" <<'EOF'
import net
out(delete("http://127.0.0.1:4481/x"))
EOF
# head() succeeds with an empty region and fails with `none`, and nothing used
# to check that a successful head isn't read as a failure.
run "head() succeeds with an empty region, not none" "region 0" <<'EOF'
import net
h = head("http://127.0.0.1:4481/x")
if h == none
    out("none")
else
    out("region " . len(h))
EOF
# Every verb reports a refused connection the same way, so a caller's
# `if r == none` test reads identically whichever verb it used.
run "every verb answers none on a refused connection" "none none none none none" <<'EOF'
import net
u = "http://127.0.0.1:9/"
out(get(u) . " " . post(u, "x") . " " . put(u, "x") . " " . delete(u) . " " . head(u))
EOF
# A body of multi-byte UTF-8 has to decode whole, and a mistake would be a body
# that decodes to almost the right thing. Fetch a 76,800-byte body twice and
# require both to be the same 67,200 code points, right through the middle.
run "a large multi-byte body decodes intact, twice" "67200 1 wörd-ünïcode- 100" <<'EOF'
import net
a = get("http://127.0.0.1:4481/big")
b = get("http://127.0.0.1:4481/big")
same = 0
if a == b
    same = 1
out(len(a) . " " . same . " " . copy(a, 0, 13) . " " . a[3])
EOF
# 2,000 fetches of that body under a 200 MB cap, each one between mark() and
# reset(). A fetch keeps everything it allocates (SPEC 12.2), and each of these
# responses is over half a megabyte decoded, so 2,000 of them only fit because
# the reset gives each one back. mark/reset is how a program says it isn't
# keeping this one. The next case is a loop that doesn't need it.
cat > "$tmp/poll.w" <<'EOF'
import sys
i = 0
total = 0
loop i < 2000
    m = mark()
    total = total + len(get("http://127.0.0.1:4481/big"))
    reset(m)
    i = i + 1
out(total)
EOF
if "$WORD" build "$tmp/poll.w" -o "$tmp/poll" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; timeout 180 "$tmp/poll" 2>"$tmp/err") )
  if [ "$got" = "134400000" ]; then ok "2,000 fetches in a mark/reset loop stay inside a 200 MB cap"
  else bad "fetch loop under a cap" "got [$got]$( [ -s "$tmp/err" ] && printf '; stderr: %s' "$(head -1 "$tmp/err")")"; fi
else bad "fetch loop under a cap" "build failed"; fi

# A poller, the ordinary program that shouldn't need `sys` at all: 4,000
# fetches of a small body, each answer measured and dropped, with no mark/reset
# anywhere, under the same 200 MB cap. A plain http:// fetch keeps 7 to 8 KB
# besides its response (SPEC 12.2): one read buffer per exchange and the buffer
# the response is appended into. It used to allocate a fresh 16 KB buffer on
# every read and rebuild the whole response each time, so a 77 KB response was
# built five times over, 237 KB in all.
cat > "$tmp/poll2.w" <<'EOF'
i = 0
total = 0
loop i < 4000
    total = total + len(get("http://127.0.0.1:4481/x"))
    i = i + 1
out(total)
EOF
if "$WORD" build "$tmp/poll2.w" -o "$tmp/poll2" >/dev/null 2>&1; then
  got=$( (ulimit -v 200000; timeout 180 "$tmp/poll2" 2>"$tmp/err") )
  if [ "$got" = "64000" ]; then ok "4,000 fetches with NO mark/reset stay inside the same 200 MB cap"
  else bad "poller without sys" "got [$got]$( [ -s "$tmp/err" ] && printf '; stderr: %s' "$(head -1 "$tmp/err")")"; fi
else bad "poller without sys" "build failed"; fi

kill "$(cat "$tmp/http.pid")" 2>/dev/null; rm -f "$tmp/http.pid"
fi

# ---------------------------------------------------------------------------
echo ""
echo "== every verb over https://, and the insecure flag =="
if ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1; then
  echo "  SKIP: needs python3 + openssl (dev/CI oracles)"
else
  # A self-signed certificate whose issuer is in no trust store: the case the
  # flag exists for, and the one default verification must refuse.
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/s.key" -out "$tmp/s.crt" \
    -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" -sha256 >"$tmp/ssl.log" 2>&1
  if [ ! -s "$tmp/s.crt" ]; then
    # openssl is on PATH, so this isn't a missing tool to skip past: every case
    # below would go unrun while the suite stayed green. That happened on
    # Windows before the MSYS settings at the top.
    bad "mint the test certificate" "openssl is present and could not, so no https:// case ran"
    sed 's/^/    | /' "$tmp/ssl.log"
  else
  python3 "$tmp/echo.py" 4447 "$tmp/s.crt" "$tmp/s.key" >/dev/null 2>&1 & echo $! > "$tmp/tls.pid"
  sleep 2

  # The case that matters most: with no flag the chain is checked, and an
  # untrusted one fails closed, with `none` and never a body.
  run "no flag: an untrusted certificate is refused (fails closed)" "refused" <<'EOF'
import net
b = get("https://127.0.0.1:4447/x")
if b == none
    out("refused")
else
    out("SERVED " . len(b))
EOF
  # A verified fetch reads and parses the whole trust store, and gives it back
  # once the chain is checked: the check runs between mark() and reset() in
  # net_tls_handshake. Before that, every verified fetch kept the parsed store,
  # close to 3 MB with a Linux bundle, and 300 refused fetches needed 840 MB.
  # Now they fit under the same 200 MB cap as the pollers above.
  cat > "$tmp/trust.w" <<'EOF'
import net
i = 0
refused = 0
loop i < 300
    if get("https://127.0.0.1:4447/x") == none
        refused = refused + 1
    i = i + 1
out(refused)
EOF
  if "$WORD" build "$tmp/trust.w" -o "$tmp/trust" >/dev/null 2>&1; then
    got=$( (ulimit -v 200000; timeout 180 "$tmp/trust" 2>/dev/null) )
    if [ "$got" = 300 ]; then ok "300 verified fetches give their trust store back (200 MB cap)"
    else bad "verified fetches under a cap" "got [$got]"; fi
  else bad "verified fetches under a cap" "build failed"; fi
  # An explicit false mustn't turn verification off by accident.
  run "get(url, false) still verifies" "refused" <<'EOF'
import net
b = get("https://127.0.0.1:4447/x", false)
if b == none
    out("refused")
else
    out("SERVED " . len(b))
EOF
  # Every verb verifies by default, not just get(). All four run in one
  # process, which also guards against the bug below.
  run "post/put/delete/head all verify by default too" "none none none none" <<'EOF'
import net
u = "https://127.0.0.1:4447/x"
out(post(u, "x") . " " . put(u, "x") . " " . delete(u) . " " . head(u))
EOF
  # A refused certificate must not poison the process. The failing request used
  # to leave its socket open, which leaked a descriptor and left the peer
  # waiting mid-handshake. Against a server that completes its handshake inside
  # accept(), as this one does, the next https:// request was never accepted
  # and blocked forever in read(). A failed request has to answer none and leave
  # the program running (SPEC 12.2).
  run "a refused certificate does not poison the process" "refused 10/10" <<'EOF'
import net
u = "https://127.0.0.1:4447/x"
i = 0
n = 0
loop i < 10
    if get(u) == none
        n = n + 1
    i = i + 1
out("refused " . n . "/10")
EOF
  # ...and a failure mustn't spoil a later success in the same process either.
  run "a success after a failure still works" "true served" <<'EOF'
import net
u = "https://127.0.0.1:4447/x"
a = get(u) == none
b = get(u, true)
if len(b) > 0
    out(a . " served")
else
    out(a . " empty")
EOF
  # The same large body over TLS, where the response arrives as many records
  # appended one at a time, so the buffer holding it was grown, not written in
  # one pass.
  run "a large multi-byte body survives the TLS record loop" "67200 wörd-ünïcode- 100" <<'EOF'
import net
a = get("https://127.0.0.1:4447/big", true)
out(len(a) . " " . copy(a, 0, 13) . " " . a[3])
EOF
  # And insecure works on every verb, over a real TLS 1.3 handshake.
  run "insecure completes the handshake for every verb" "METHOD=GET len=0/METHOD=POST len=3/METHOD=PUT len=2/METHOD=DELETE len=0/region 0" <<'EOF'
import net
u = "https://127.0.0.1:4447/x"
h = head(u, true)
line = get(u, true) . "/" . post(u, "abc", true) . "/" . put(u, "de", true) . "/" . delete(u, true) . "/"
if h == none
    out(line . "none")
else
    out(line . "region " . len(h))
EOF
  # A refusal must say why on stderr, so the `none` can be diagnosed, and the
  # message mustn't end up on stdout with the value.
  cat > "$tmp/d.w" <<'EOF'
import net
b = get("https://127.0.0.1:4447/x")
out(b == none)
EOF
  if "$WORD" build "$tmp/d.w" -o "$tmp/d" >/dev/null 2>&1; then
    timeout 30 "$tmp/d" >"$tmp/dout" 2>"$tmp/err"
    if grep -q "not trusted" "$tmp/err" && [ "$(cat "$tmp/dout")" = true ]; then
      ok "a refusal names the reason on stderr, and stdout carries only the value"
    else
      bad "refusal diagnostic" "stdout=[$(cat "$tmp/dout")] stderr=[$(head -1 "$tmp/err")]"
    fi
  else bad "refusal diagnostic" "build failed"; fi
  kill "$(cat "$tmp/tls.pid")" 2>/dev/null; rm -f "$tmp/tls.pid"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "== a server that asks for a client certificate =="
# A TLS 1.3 server may ask the client to authenticate too, with a
# CertificateRequest in its flight (RFC 8446 4.3.2). This client has no
# certificate to present, and 4.4.2 says what it sends then: a Certificate with
# an empty list, echoing the request's context, and its Finished over a
# transcript that includes it. The server decides what that is worth (4.4.2.4):
# it carries on without client authentication, or refuses with
# certificate_required (116).
#
# This client used to not recognize a flight carrying a request, so it waited
# for bytes the server was never going to send while the server waited for its
# answer: the whole 30 s idle deadline, then `none` with nothing on stderr.
# Each case here must answer in under 10 s, and a 25 s cap turns a stall into a
# failure instead of a hang.
#
# openssl s_server is on the other end, and it checks the client's Finished, so
# a transcript that's wrong by one message is a refusal here, not a pass. The
# fetches are `insecure` because this certificate is in no trust store;
# test_tls_server.sh makes the same request against a chain that verifies.
if ! command -v openssl >/dev/null 2>&1; then
  echo "  SKIP: needs openssl (dev/CI oracle)"
else
  openssl ecparam -name prime256v1 -genkey -noout -out "$tmp/cr.key" >"$tmp/cr_ssl.log" 2>&1
  openssl req -x509 -new -key "$tmp/cr.key" -out "$tmp/cr.crt" -days 2 -sha256 \
    -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" >>"$tmp/cr_ssl.log" 2>&1
  # And a certificate whose keyUsage has no bits, which this client's decoder
  # refuses (SPEC 12.2's profile, rule 5). That refusal used to come too late in
  # the same way: the flight was complete, the client couldn't accept it, and
  # it read on as if more were coming.
  printf 'basicConstraints=CA:FALSE\n2.5.29.15=critical,DER:03:01:00\nsubjectAltName=IP:127.0.0.1\n' > "$tmp/ku.ext"
  openssl req -new -key "$tmp/cr.key" -out "$tmp/ku.csr" -subj "/CN=127.0.0.1" >>"$tmp/cr_ssl.log" 2>&1
  openssl x509 -req -in "$tmp/ku.csr" -signkey "$tmp/cr.key" -out "$tmp/ku.crt" -days 2 \
    -sha256 -extfile "$tmp/ku.ext" >>"$tmp/cr_ssl.log" 2>&1
  cat > "$tmp/cr.w" <<'EOF'
import net
a = args()
b = get("https://127.0.0.1:" . a[1] . "/", true)
if b == none
    out("none")
else
    out("body")
EOF
  if [ ! -s "$tmp/cr.crt" ] || [ ! -s "$tmp/ku.crt" ]; then
    # openssl is on PATH, so as above this isn't a missing tool to skip past.
    bad "mint the certificate-request certificates" "openssl is present and could not, so no case here ran"
    sed 's/^/    | /' "$tmp/cr_ssl.log"
  elif ! "$WORD" build "$tmp/cr.w" -o "$tmp/cr" >"$tmp/cr_err" 2>&1; then
    bad "a server that asks for a client certificate" "build failed: $(head -1 "$tmp/cr_err")"
  else
    # cr_case <name> <want stdout> <stderr must say, or ""> <port> <cert> <s_server flags...>
    cr_case() {
      nm=$1; want=$2; says=$3; port=$4; crt=$5; shift 5
      openssl s_server -accept "127.0.0.1:$port" -www -naccept 1 -tls1_3 \
        -cert "$crt" -key "$tmp/cr.key" "$@" >"$tmp/cr_srv.log" 2>&1 &
      echo $! > "$tmp/cr.pid"
      sleep 2
      t0=$(date +%s%N)
      got=$(timeout 25 "$tmp/cr" "$port" 2>"$tmp/cr_err"); rc=$?
      ms=$(( ($(date +%s%N) - t0) / 1000000 ))
      kill "$(cat "$tmp/cr.pid")" 2>/dev/null; rm -f "$tmp/cr.pid"
      if [ "$rc" = 124 ]; then
        bad "$nm" "no answer in 25 s: the stall this section is for"
      elif [ "$got" != "$want" ] || [ "$rc" != 0 ]; then
        bad "$nm" "got [$got] rc=$rc want [$want]; stderr: $(head -1 "$tmp/cr_err")"
      elif [ -n "$says" ] && ! grep -qF "$says" "$tmp/cr_err"; then
        bad "$nm" "stderr [$(head -1 "$tmp/cr_err")] does not say [$says]"
      elif [ -z "$says" ] && [ -s "$tmp/cr_err" ]; then
        bad "$nm" "stderr should be empty: $(head -1 "$tmp/cr_err")"
      elif [ "$ms" -ge 10000 ]; then
        bad "$nm" "took $ms ms: that is waiting out the idle deadline, not answering"
      else
        ok "$nm"
      fi
    }
    cr_case "optional (-verify 1): the empty Certificate is accepted and the fetch answers" \
      body "" 4449 "$tmp/cr.crt" -verify 1
    cr_case "required (-Verify 1): refused at once, and the alert is named" \
      none "refused the handshake, alert 116" 4450 "$tmp/cr.crt" -Verify 1
    cr_case "a certificate the decoder refuses fails at once, not at the idle deadline" \
      none "could not accept" 4451 "$tmp/ku.crt"
  fi
fi

echo ""
echo "test_net_verbs: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
