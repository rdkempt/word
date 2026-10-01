#!/bin/sh
# test_net_limits.sh: the bounds a fetch runs under (SPEC 12.2), and how it
# reads a response's framing.
#
# `net` talks to peers it doesn't control, and it used to have no way to give
# up on one. With no read deadline, a server that accepted the connection and
# then said nothing held the program as long as it liked, and with no ceiling
# on the response, a body the peer kept sending grew until the machine ran out
# of memory. A wedged server does both by accident, and neither gave the caller
# a failure it could recover from. The ceilings are 64 MiB for a body and
# 64 KiB for a TLS handshake flight.
#
# Once a read can time out, a stalled peer looks like a peer that hung up, so a
# response that declared its length and stopped short would come back as a
# short body. That's worse than hanging, because the caller parses half a
# document and can't tell, so a truncated response is a failure too. The case
# that must not become one, a body framed by the close itself, is checked
# beside it.
#
# Then the step before those: a peer that never answers the TCP handshake,
# which connect() gives up on after ten seconds. And two peers that answer a
# byte at a time (a TLS server trickling its handshake and a resolver trickling
# a TCP answer), which a deadline per read never catches: the total deadline
# covers the whole fetch, handshake included, and a DNS answer over TCP has a
# budget of its own. The ServerHello and HelloRetryRequest checks are here too.
#
# The second half is how a response is framed and how a request is built,
# against the same fixture: interim 1xx responses before the real one, a reply
# to HEAD that names a length it never sends, a Content-Length that isn't a
# length, a chunk size that isn't a size, and a URL that tries to write request
# lines of its own. Each of those was a wrong answer, a thirty-second stall or a
# fault before it had a test.
#
# Everything runs against 127.0.0.1, so this needs no root and no external
# network, except the unanswered-handshake case on a system that refuses a
# handshake instead of leaving it unanswered, which goes to a documentation
# address nothing routes. python3 is a test tool only; nothing needs it to
# build or run word.
#
# No `set -e`: most cases expect a failed request.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
WORD=$(wordbin "${WORD:-$root/word}")
cd "$root"          # uniform cwd; net builds are self-contained (the library is in the binary)
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "test_net_limits: SKIP (no python3)"; exit 0; }

tmp=$(hostpath "$(mktemp -d)"); pass=0; fail=0
cleanup() {
  for f in "$tmp"/*.pid; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }

# A raw socket server instead of http.server: most cases here need a response
# that isn't well formed, and the standard library's server won't send one.
cat > "$tmp/srv.py" <<'PY'
import socket, sys, threading, time

PORT = int(sys.argv[1])
CAP  = 64 * 1024 * 1024          # net_max_body() in the net library's net.w


def head_then_hold(c, head):
    # Sends a head that names a body and then keeps the socket open without
    # sending it: a client that waits for that body waits out its own deadline.
    c.sendall(head)
    time.sleep(60)


def handle(c):
    try:
        c.settimeout(20)
        req = b""
        while b"\r\n\r\n" not in req:
            b = c.recv(4096)
            if not b:
                return
            req += b
        path = req.split(b" ")[1].decode("latin-1")
        head, _, rest = req.partition(b"\r\n\r\n")

        if path.startswith("/echo") or path.startswith("/?"):
            # The request line and Host header as they arrived, and the body's
            # bytes in hex, so the test sees what was on the wire.
            lines = head.split(b"\r\n")
            host = [l for l in lines if l.lower().startswith(b"host:")]
            n = 0
            for l in lines:
                if l.lower().startswith(b"content-length:"):
                    n = int(l.split(b":")[1])
            while len(rest) < n:
                more = c.recv(4096)
                if not more:
                    break
                rest += more
            text = lines[0] + b"|" + b"|".join(host) + b"|" + rest[:n].hex().encode()
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(text) + text)

        elif path == "/early":
            # RFC 9110 15.2: interim responses first, then the answer.
            c.sendall(b"HTTP/1.1 103 Early Hints\r\nLink: </x>; rel=preload\r\n\r\n"
                      b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")

        elif path == "/interims":
            c.sendall(b"HTTP/1.1 100 Continue\r\n\r\n"
                      b"HTTP/1.1 102 Processing\r\n\r\n"
                      b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nworld")

        elif path == "/switch":
            # 101 answers a request for an Upgrade, which this client never sends.
            c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n"
                      b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno")

        elif path == "/hugelength":
            # Thirty digits: used to be an integer overflow inside the client.
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999999999999\r\n\r\nabc")

        elif path == "/badlength":
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 12abc\r\n\r\nabc")

        elif path == "/overceiling":
            # Declares more than the client will read, then sends nothing.
            head_then_hold(c, b"HTTP/1.1 200 OK\r\nContent-Length: 100000000\r\n\r\n")

        elif path == "/headhold":
            # What a server answers HEAD with: the length a GET would have had.
            head_then_hold(c, b"HTTP/1.1 200 OK\r\nContent-Length: 500000000\r\n\r\n")

        elif path == "/nocontent":
            head_then_hold(c, b"HTTP/1.1 204 No Content\r\nContent-Length: 100\r\n\r\n")

        elif path == "/notmodified":
            head_then_hold(c, b"HTTP/1.1 304 Not Modified\r\nContent-Length: 1234\r\n\r\n")

        elif path == "/truncated":
            # Says 1000 bytes and sends 10, then hangs up. A client must not hand
            # this back as a body.
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\n0123456789")

        elif path == "/closedelim":
            # No Content-Length and no chunking: the close is the framing, so
            # this one is complete and must succeed.
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nCLOSE-DELIMITED-BODY")

        elif path == "/chunktrunc":
            # A chunked body that stops before the zero chunk.
            c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")

        elif path == "/badchunk":
            # A chunked head and a size line that isn't a size, then the socket
            # held open. No more bytes can make this body complete.
            head_then_hold(c, b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n")

        elif path == "/bigchunked":
            # 16 MiB in 1 KiB chunks: a quarter of the ceiling, in chunks of an
            # ordinary size for a streaming server.
            c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            piece = b"400\r\n" + b"x" * 1024 + b"\r\n"
            for _ in range(16384):
                c.sendall(piece)
            c.sendall(b"0\r\n\r\n")

        elif path == "/biglength":
            # The same body framed by Content-Length, for comparison.
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 16777216\r\n\r\n")
            block = b"x" * 65536
            for _ in range(256):
                c.sendall(block)

        elif path == "/endlesshead":
            # A head that never ends: 40 MiB of one header's value, under the
            # ceiling, and then the close.
            c.sendall(b"HTTP/1.1 200 OK\r\nX-Pad: ")
            block = b"a" * 65536
            for _ in range(640):
                c.sendall(block)

        elif path == "/huge":
            # Close-delimited and endless, so nothing but the client's own
            # ceiling stops it. Sends a little past the cap and then gives up,
            # so a client that never stops does not fill the runner's disk.
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
            block = b"x" * 65536
            sent = 0
            while sent < CAP + (4 << 20):
                c.sendall(block)
                sent += len(block)

        elif path == "/stall":
            # Accepts, answers nothing, holds the socket open. This is the case
            # that used to hold the client for ever.
            time.sleep(300)

        else:
            c.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT))
s.listen(16)
print("ready", flush=True)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY

PORT=8137
python3 "$tmp/srv.py" $PORT > "$tmp/srv.out" 2>&1 &
echo $! > "$tmp/srv.pid"
i=0
while [ "$i" -lt 50 ]; do
  grep -q ready "$tmp/srv.out" 2>/dev/null && break
  i=$((i + 1)); sleep 0.2
done
grep -q ready "$tmp/srv.out" 2>/dev/null || { echo "FAIL: the fixture server did not start"; exit 1; }

# A peer that trickles: it takes whatever the client sends first, answers with
# a header promising more than it will ever deliver, and sends it a byte at a
# time, always inside the idle deadline and never finished. The socket only
# gives a deadline per read, which this never trips; only a deadline over the
# whole exchange catches it.
cat > "$tmp/trickle.py" <<'PY'
import socket, sys, threading, time

PORT, HEAD, EVERY = int(sys.argv[1]), bytes.fromhex(sys.argv[2]), float(sys.argv[3])


def handle(c):
    try:
        c.settimeout(5)
        try:
            c.recv(4096)
        except Exception:
            pass
        c.sendall(HEAD)
        while True:
            c.sendall(b"\x00")
            time.sleep(EVERY)
    except Exception:
        pass


s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", PORT))
s.listen(4)
print("ready", flush=True)
while True:
    conn, _ = s.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
PY
# trickle <pidfile> <port> <header hex> <seconds between bytes>
trickle() {
  python3 "$tmp/trickle.py" "$2" "$3" "$4" > "$tmp/$1.out" 2>&1 &
  echo $! > "$tmp/$1.pid"
  j=0
  while [ "$j" -lt 50 ]; do
    grep -q ready "$tmp/$1.out" 2>/dev/null && return 0
    j=$((j + 1)); sleep 0.2
  done
  return 1
}

# A TLS server that trickles its handshake: a record header promising 16 KB of
# handshake, then a byte a second. The total deadline used to start only once
# the handshake was over, so this held a fetch for as long as the server kept
# going. It takes the whole total deadline (two minutes) to give up, so it
# starts here, runs beside the other cases, and is judged at the end.
DRIP=8139
dripjob=""
if ! trickle hs "$DRIP" 1603034000 1; then
  bad "a TLS handshake trickled a byte at a time" "the trickling server did not start"
else
  cat > "$tmp/drip.w" <<W
b = get("https://127.0.0.1:$DRIP/")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W
  if ! "$WORD" build "$tmp/drip.w" -o "$tmp/drip" >/dev/null 2>&1; then
    bad "a TLS handshake trickled a byte at a time" "build failed"
  else
    ( start=$(date +%s)
      got=$(timeout 180 "$tmp/drip" 2>"$tmp/drip.err"); rc=$?
      echo "$rc $(( $(date +%s) - start )) $got" > "$tmp/drip.res" ) &
    dripjob=$!
  fi
fi

# run <name> <expected-stdout> <cap-seconds> ; program on stdin.
run() { cat > "$tmp/p.w"; nm="$1"; want="$2"; cap="$3"
  if ! "$WORD" build "$tmp/p.w" -o "$tmp/p" >/dev/null 2>&1; then bad "$nm" "build failed"; return; fi
  start=$(date +%s)
  got=$(timeout "$cap" "$tmp/p" 2>"$tmp/err"); rc=$?
  took=$(( $(date +%s) - start ))
  if [ "$rc" = 124 ]; then bad "$nm" "still running after ${cap}s: the bound did not hold"; return; fi
  if [ "$got" = "$want" ] && [ "$rc" = 0 ]; then ok "$nm (${took}s)"
  else bad "$nm" "got [$got] rc=$rc want [$want]$( [ -s "$tmp/err" ] && printf '; stderr: %s' "$(head -1 "$tmp/err")")"; fi; }

echo "== a response that stops short of the length it declared is a failure, not a short body =="
run "Content-Length says 1000, ten bytes arrive" TRUNCATED 30 <<W
b = get("http://127.0.0.1:$PORT/truncated")
if b == none
    out("TRUNCATED")
else
    out("GOT " . len(b) . " BYTES")
W

run "a chunked body that never sends the zero chunk" TRUNCATED 30 <<W
b = get("http://127.0.0.1:$PORT/chunktrunc")
if b == none
    out("TRUNCATED")
else
    out("GOT " . len(b) . " BYTES")
W

echo
echo "== and the control: a body framed by the close is allowed to end by ending =="
run "no Content-Length, no chunking, peer hangs up" "CLOSE-DELIMITED-BODY" 30 <<W
b = get("http://127.0.0.1:$PORT/closedelim")
if b == none
    out("NONE")
else
    out(b)
W

echo
echo "== a peer that never answers loses the connection instead of keeping the program =="
# net_idle_ms() is 30 s, so this must return inside about that. 90 s is the cap
# that tells a slow runner apart from a client with no deadline at all.
run "a server that accepts and then says nothing" NONE 90 <<W
b = get("http://127.0.0.1:$PORT/stall")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

echo
echo "== a body larger than the client will read is refused, not accumulated =="
# net_max_body() is 64 MiB. Without the ceiling this reads until the arena
# cannot grow, which on a runner is a kill rather than a return.
run "an endless close-delimited body" NONE 120 <<W
b = get("http://127.0.0.1:$PORT/huge")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

echo
echo "== a chunked body is decoded in one pass, into one copy =="
# The body used to be put back together a chunk at a time, keeping every
# intermediate copy in the arena: about 137 GB for this one, so a 4 GiB address
# space ran out of memory on a body a quarter of the ceiling. Under a 512 MB cap
# it has to come back whole, the same as the body framed by Content-Length.
# Where `ulimit -v` does nothing (Windows), the case still checks the body.
for framing in bigchunked biglength; do
  printf 'b = get("http://127.0.0.1:%s/%s")\nif b == none\n    out("NONE")\nelse\n    out(len(b))\n' \
    "$PORT" "$framing" > "$tmp/p.w"
  if ! "$WORD" build "$tmp/p.w" -o "$tmp/p" >/dev/null 2>&1; then bad "$framing" "build failed"; continue; fi
  start=$(date +%s)
  got=$( ( ulimit -v 524288 2>/dev/null; exec timeout 120 "$tmp/p" ) 2>"$tmp/err" ); rc=$?
  took=$(( $(date +%s) - start ))
  if [ "$got" = 16777216 ] && [ "$rc" = 0 ]; then ok "16 MiB, $framing, inside 512 MB (${took}s)"
  else bad "16 MiB, $framing, inside 512 MB" "got [$got] rc=$rc$( [ -s "$tmp/err" ] && printf '; stderr: %s' "$(head -1 "$tmp/err")")"; fi
done

echo
echo "== a head that never ends is searched once, not once per read =="
# The client asks after every read whether the head has all arrived, and used to
# search it from the first byte each time. For 40 MiB of head in 4 KiB reads that
# is more than 200 billion byte comparisons, well past the total deadline. Now
# each read's bytes are searched once, and the fetch is over when the peer
# closes: none, because a response with no end to its head isn't one.
run "40 MiB of head and no blank line" NONE 60 <<W
b = get("http://127.0.0.1:$PORT/endlesshead")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

echo
echo "== a TLS handshake flight larger than the client will read is refused, not accumulated =="
# net_max_flight() is 64 KiB. This needs the client to get past the ServerHello
# and into the encrypted server flight, which a raw-socket fake can't do, so the
# fixture is a from-scratch TLS 1.3 server: x25519, HKDF-SHA256 and
# ChaCha20-Poly1305 in pure Python (no `cryptography` module, since python3 is
# a bare test tool everywhere here). It completes the handshake through
# ServerHello and then streams an encrypted flight with no Finished: the first
# record's plaintext is a Certificate header claiming 2^24-1 bytes, and the
# rest is filler. Without the ceiling, the client made a full-length copy of
# the flight for every record, in an arena that never shrinks: quadratic, and
# on a runner an out-of-memory kill (exit 70, about 2.8 GB in under 8 s). With
# it, the fetch answers none with a reason after reading about 64 KiB, well
# inside the 120 s total deadline. Certificate checks are off (get(url, true))
# because the flight is refused before any certificate is looked at.
cat > "$tmp/tlsflight.py" <<'PY'
import socket, sys, threading, hashlib, hmac
P = 2**255 - 19

def x25519(k, u):
    def dsl(b):
        b = bytearray(b); b[0] &= 248; b[31] &= 127; b[31] |= 64
        return int.from_bytes(b, 'little')
    def duc(u):
        u = bytearray(u); u[31] &= 127
        return int.from_bytes(u, 'little')
    kk = dsl(k); x1 = duc(u); x2, z2, x3, z3 = 1, 0, x1, 1; swap = 0; a24 = 121665
    for t in range(254, -1, -1):
        kt = (kk >> t) & 1; swap ^= kt
        if swap:
            x2, x3 = x3, x2; z2, z3 = z3, z2
        swap = kt
        A = (x2 + z2) % P; AA = A * A % P; B = (x2 - z2) % P; BB = B * B % P
        E = (AA - BB) % P; C = (x3 + z3) % P; D = (x3 - z3) % P
        DA = D * A % P; CB = C * B % P
        x3 = pow((DA + CB) % P, 2, P); z3 = x1 * pow((DA - CB) % P, 2, P) % P
        x2 = AA * BB % P; z2 = E * ((AA + a24 * E % P) % P) % P
    if swap:
        x2, x3 = x3, x2; z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, 'little')

def hk_ext(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()

def hk_exp(prk, info, n):
    t = b""; okm = b""; i = 0
    while len(okm) < n:
        i += 1; t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest(); okm += t
    return okm[:n]

def hk_lbl(secret, label, ctx, n):
    full = b"tls13 " + label
    info = n.to_bytes(2, 'big') + bytes([len(full)]) + full + bytes([len(ctx)]) + ctx
    return hk_exp(secret, info, n)

def rol(v, c):
    return ((v << c) & 0xffffffff) | (v >> (32 - c))

def qr(s, a, b, c, d):
    s[a] = (s[a] + s[b]) & 0xffffffff; s[d] ^= s[a]; s[d] = rol(s[d], 16)
    s[c] = (s[c] + s[d]) & 0xffffffff; s[b] ^= s[c]; s[b] = rol(s[b], 12)
    s[a] = (s[a] + s[b]) & 0xffffffff; s[d] ^= s[a]; s[d] = rol(s[d], 8)
    s[c] = (s[c] + s[d]) & 0xffffffff; s[b] ^= s[c]; s[b] = rol(s[b], 7)

def cc_block(key, ctr, nonce):
    st = [0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]
    st += [int.from_bytes(key[i:i + 4], 'little') for i in range(0, 32, 4)]
    st += [ctr & 0xffffffff]
    st += [int.from_bytes(nonce[i:i + 4], 'little') for i in range(0, 12, 4)]
    w = list(st)
    for _ in range(10):
        qr(w, 0, 4, 8, 12); qr(w, 1, 5, 9, 13); qr(w, 2, 6, 10, 14); qr(w, 3, 7, 11, 15)
        qr(w, 0, 5, 10, 15); qr(w, 1, 6, 11, 12); qr(w, 2, 7, 8, 13); qr(w, 3, 4, 9, 14)
    return b"".join(((w[i] + st[i]) & 0xffffffff).to_bytes(4, 'little') for i in range(16))

def cc_enc(key, ctr, nonce, data):
    o = bytearray()
    for i in range(0, len(data), 64):
        ks = cc_block(key, ctr + i // 64, nonce)
        o += bytes(b ^ ks[j] for j, b in enumerate(data[i:i + 64]))
    return bytes(o)

def poly(msg, key):
    r = int.from_bytes(key[:16], 'little') & 0x0ffffffc0ffffffc0ffffffc0fffffff
    s = int.from_bytes(key[16:32], 'little'); p = (1 << 130) - 5; a = 0
    for i in range(0, len(msg), 16):
        c = msg[i:i + 16]
        a = (a + (int.from_bytes(c, 'little') | (1 << (8 * len(c))))) % p
        a = a * r % p
    return ((a + s) & ((1 << 128) - 1)).to_bytes(16, 'little')

def pad16(x):
    return b"\x00" * ((16 - len(x) % 16) % 16)

def aead(key, nonce, aad, pt):
    otk = cc_block(key, 0, nonce)[:32]; ct = cc_enc(key, 1, nonce, pt)
    m = aad + pad16(aad) + ct + pad16(ct) + len(aad).to_bytes(8, 'little') + len(ct).to_bytes(8, 'little')
    return ct + poly(m, otk)

def seal(key, iv, seq, pt, ct):
    inner = pt + bytes([ct]); el = len(inner) + 16
    aad = bytes([23, 3, 3, (el >> 8) & 255, el & 255]); nn = bytearray(iv); ss = seq
    for j in range(8):
        nn[11 - j] ^= ss & 255; ss >>= 8
    return aad + aead(key, bytes(nn), aad, inner)

def recvn(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            return None
        b += d
    return b

def parse_ch(ch):
    body = ch[4:]; off = 34; sl = body[off]; off += 1
    sid = body[off:off + sl]; off += sl
    csl = (body[off] << 8) | body[off + 1]; off += 2 + csl
    off += 1 + body[off]
    el = (body[off] << 8) | body[off + 1]; off += 2; end = off + el; pub = None
    while off + 4 <= end:
        et = (body[off] << 8) | body[off + 1]; ln = (body[off + 2] << 8) | body[off + 3]; off += 4
        if et == 51:
            p = off + 2
            while p + 4 <= off + ln:
                g = (body[p] << 8) | body[p + 1]; kl = (body[p + 2] << 8) | body[p + 3]; p += 4
                if g == 29:
                    pub = body[p:p + kl]
                p += kl
        off += ln
    return sid, pub

def sh(sid, spub):
    ext = bytes([0, 0x2b, 0, 2, 3, 4])
    ks = bytes([0, 0x1d]) + len(spub).to_bytes(2, 'big') + spub
    ext += bytes([0, 0x33]) + len(ks).to_bytes(2, 'big') + ks
    b = bytes([3, 3]) + b"\x5a" * 32 + bytes([len(sid)]) + sid + bytes([0x13, 3, 0]) + len(ext).to_bytes(2, 'big') + ext
    return bytes([2]) + len(b).to_bytes(3, 'big') + b

def prec(ct, pl):
    return bytes([ct, 3, 3]) + len(pl).to_bytes(2, 'big') + pl

def handle(c, cap, rp):
    try:
        c.settimeout(30)
        h = recvn(c, 5)
        if not h:
            return
        ch = recvn(c, (h[3] << 8) | h[4])
        if not ch:
            return
        sid, cpub = parse_ch(ch)
        if cpub is None:
            return
        priv = bytes(range(32)); spub = x25519(priv, bytes([9] + [0] * 31))
        shm = sh(sid, spub); c.sendall(prec(22, shm))
        ecdhe = x25519(priv, cpub); th = hashlib.sha256(ch + shm).digest()
        early = hk_ext(b"\x00" * 32, b"\x00" * 32)
        drv = hk_lbl(early, b"derived", hashlib.sha256(b"").digest(), 32)
        hs = hk_ext(drv, ecdhe); shs = hk_lbl(hs, b"s hs traffic", th, 32)
        skey = hk_lbl(shs, b"key", b"", 32); siv = hk_lbl(shs, b"iv", b"", 12)
        seq = 0; sent = 0
        pl = bytes([0x0b, 0xff, 0xff, 0xff]) + b"\x00" * (rp - 4)
        while cap == 0 or sent < cap:
            c.sendall(seal(skey, siv, seq, pl, 22)); seq += 1; sent += len(pl); pl = b"\x41" * rp
    except Exception:
        pass
    finally:
        try:
            c.close()
        except Exception:
            pass

def main():
    port = int(sys.argv[1]); cap = int(sys.argv[2]); rp = int(sys.argv[3])
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", port)); s.listen(8); print("ready", flush=True)
    while True:
        conn, _ = s.accept()
        threading.Thread(target=handle, args=(conn, cap, rp), daemon=True).start()

main()
PY
FLP=8141
python3 "$tmp/tlsflight.py" $FLP 0 16384 > "$tmp/tlsflight.out" 2>&1 &
echo $! > "$tmp/tlsflight.pid"
j=0
while [ "$j" -lt 50 ]; do
  grep -q ready "$tmp/tlsflight.out" 2>/dev/null && break
  j=$((j + 1)); sleep 0.2
done
nm="a TLS flight past the 64 KiB ceiling is refused with a reason"
if ! grep -q ready "$tmp/tlsflight.out" 2>/dev/null; then
  bad "$nm" "the flight server did not start: $(head -1 "$tmp/tlsflight.out")"
else
  cat > "$tmp/p.w" <<W
b = get("https://127.0.0.1:$FLP/", true)
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W
  if ! "$WORD" build "$tmp/p.w" -o "$tmp/p" >/dev/null 2>&1; then bad "$nm" "build failed"
  else
    start=$(date +%s)
    got=$(timeout 60 "$tmp/p" 2>"$tmp/err"); rc=$?
    took=$(( $(date +%s) - start ))
    if [ "$rc" = 124 ]; then bad "$nm" "still running after 60s: the flight has no ceiling"
    elif [ "$got" != NONE ] || [ "$rc" != 0 ]; then bad "$nm" "got [$got] rc=$rc want [NONE]$( [ -s "$tmp/err" ] && printf '; stderr: %s' "$(head -1 "$tmp/err")")"
    elif ! grep -q "handshake flight is larger" "$tmp/err"; then bad "$nm" "no reason on stderr: [$(head -1 "$tmp/err")]"
    elif [ "$took" -gt 30 ]; then bad "$nm" "gave up after ${took}s, not promptly at the ceiling"
    else ok "$nm (${took}s)"; fi
  fi
fi

echo
echo "== a peer that never answers the handshake is given up on at connect =="
# connect() waits ten seconds for the TCP handshake (connect_secs in the
# compiler). It used to wait the kernel's own timeout: about two minutes on
# Linux, 21 s on Windows. Nothing above connect() could set a shorter one,
# because the socket doesn't exist until connect() makes it.
#
# The silent peer is a listener whose accept queue is full, which Linux answers
# by dropping the SYN, so the client retransmits until its own deadline.
# Windows refuses instead, and there the peer is 192.0.2.1 (TEST-NET-1, RFC
# 5737, which nothing routes), the one packet in this suite that leaves the
# host. A peer is used only once a probe has found it silent for five seconds,
# because a Windows client retries a refused handshake twice and reports the
# refusal about two seconds in, which a shorter probe would take for silence.
# With no silent peer the case skips. The fetch has to fail after the deadline
# and not before it: an upper limit alone would pass a deadline far shorter
# than intended.
cat > "$tmp/hole.py" <<'PY'
import socket, sys, time

PORT = int(sys.argv[1])


def silent(host, port, wait):
    s = socket.socket()
    s.settimeout(wait)
    try:
        s.connect((host, port))
        return False
    except socket.timeout:
        return True
    except OSError:
        return False
    finally:
        s.close()


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(0)
held = []
for _ in range(2):
    c = socket.socket()
    c.setblocking(False)
    c.connect_ex(("127.0.0.1", PORT))
    held.append(c)
time.sleep(0.5)
if silent("127.0.0.1", PORT, 5):
    print("127.0.0.1", PORT, flush=True)
elif silent("192.0.2.1", 80, 5):
    print("192.0.2.1", 80, flush=True)
else:
    print("none", flush=True)
time.sleep(600)
PY
python3 "$tmp/hole.py" 8138 > "$tmp/hole.out" 2>&1 &
echo $! > "$tmp/hole.pid"
i=0
while [ "$i" -lt 100 ]; do
  [ -s "$tmp/hole.out" ] && break
  i=$((i + 1)); sleep 0.2
done
peer=$(head -1 "$tmp/hole.out")
case "$peer" in
  ""|none) echo "  SKIP: no peer here leaves a handshake unanswered" ;;
  *)
    set -- $peer
    cat > "$tmp/p.w" <<W
b = get("http://$1:$2/")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W
    nm="a peer at $1:$2 that never answers the handshake"
    if ! "$WORD" build "$tmp/p.w" -o "$tmp/p" >/dev/null 2>&1; then bad "$nm" "build failed"
    else
      start=$(date +%s)
      got=$(timeout 60 "$tmp/p" 2>"$tmp/err"); rc=$?
      took=$(( $(date +%s) - start ))
      if [ "$rc" = 124 ]; then bad "$nm" "still running after 60s: connect() has no deadline"
      elif [ "$got" != NONE ] || [ "$rc" != 0 ]; then bad "$nm" "got [$got] rc=$rc want [NONE]"
      elif [ "$took" -lt 8 ]; then bad "$nm" "gave up after ${took}s, before the ten-second deadline"
      elif [ "$took" -gt 18 ]; then bad "$nm" "gave up after ${took}s, well past the ten-second deadline"
      else ok "$nm (${took}s)"; fi
    fi ;;
esac

echo
echo "== a resolver that trickles its answer over TCP is given up on =="
# DNS retries over TCP, and that answer used to have only a read deadline, which
# a resolver sending a byte every half second never trips. It has five seconds
# in all now (dns_tcp_ms). A lookup goes to port 53, which a test can't bind
# without root, so this calls dns.w itself with the port it's given.
# netlib_cat.py copies dns.w out of the compiler's net library into the
# program, the way test_crypto_w.sh builds one.
DNSP=8140
if ! trickle dns "$DNSP" 00c8 0.5; then
  bad "a DNS answer over TCP trickled a byte at a time" "the trickling resolver did not start"
else
  { echo "import sys"
    python3 "$root/dev/toolchain/netlib_cat.py" dns
    cat <<W
lo = bytes(4)
lo[0] = 127
lo[3] = 1
t0 = now()
r = dns_ask_tcp(lo, $DNSP, dns_query("example.com", 4660), 4660)
took = now() - t0
// The rest of dns.w is only reachable through dns_resolve, and a program has to
// use every function it defines. A dotted quad answers itself, off the network.
out(kind(r) . " " . took . " " . len(dns_resolve("203.0.113.9")))
W
  } > "$tmp/dnsdrip.w"
  nm="a DNS answer over TCP trickled a byte at a time"
  if ! "$WORD" build "$tmp/dnsdrip.w" -o "$tmp/dnsdrip" >"$tmp/err" 2>&1; then
    bad "$nm" "build failed: $(head -1 "$tmp/err")"
  else
    got=$(timeout 60 "$tmp/dnsdrip" 2>&1); rc=$?
    set -- $got
    if [ "$rc" = 124 ]; then bad "$nm" "still running after 60s: the answer has no budget"
    elif [ "$rc" != 0 ] || [ "$1" != number ] || [ "$3" != 4 ]; then bad "$nm" "got [$got] rc=$rc, want a failed lookup"
    else
      secs=$(( $2 / 1000000000 ))
      if [ "$secs" -lt 4 ]; then bad "$nm" "gave up after ${secs}s, before its five-second budget"
      elif [ "$secs" -gt 10 ]; then bad "$nm" "gave up after ${secs}s, well past its five-second budget"
      else ok "$nm (${secs}s)"; fi
    fi
  fi
fi

echo
echo "== a TLS server that trickles its handshake is given up on at the total deadline =="
# Started at the top; net_total_ns() is 120 s, and the whole fetch counts.
nm="a TLS handshake trickled a byte at a time"
if [ -n "$dripjob" ]; then
  wait "$dripjob"
  read -r rc took got < "$tmp/drip.res"
  if [ "$rc" = 124 ]; then bad "$nm" "still running after 180s: the handshake is outside the total deadline"
  elif [ "$got" != NONE ] || [ "$rc" != 0 ]; then bad "$nm" "got [$got] rc=$rc want [NONE]"
  elif ! grep -q "did not finish inside the deadline" "$tmp/drip.err"; then
    bad "$nm" "no reason on stderr: [$(head -1 "$tmp/drip.err")]"
  elif [ "$took" -lt 115 ]; then bad "$nm" "gave up after ${took}s, before the 120-second deadline"
  elif [ "$took" -gt 140 ]; then bad "$nm" "gave up after ${took}s, well past the 120-second deadline"
  else ok "$nm (${took}s)"; fi
fi

echo
echo "== a ServerHello or HelloRetryRequest this client cannot accept ends the handshake =="
# RFC 8446 4.1.4 and 4.2.8: a retry naming a suite the ClientHello didn't
# offer, the group it already sent a share for, a group it never listed, or
# another session id is refused, and the ServerHello after a retry has to name
# the suite the retry named. The first four used to get a second ClientHello.
# RFC 8446 4.1.3: a ServerHello echoing another session id is refused too,
# where the client used to carry on to the key exchange. A ServerHello whose
# length runs past its record is refused instead of faulting, which it used to
# do. The fake server answers each ClientHello as its mode says, one
# connection per mode in order, and logs what came back.
cat > "$tmp/hrr.py" <<'PY'
import socket, sys

port, log = int(sys.argv[1]), sys.argv[2]
modes = sys.argv[3:]
MAGIC = bytes.fromhex("cf21ad74e59a6111be1d8c021e65b891c2a211167abb8c5e079e09e2c8a8339c")
# The P-256 generator, a valid point to stand in for a key share.
P256_G = bytes.fromhex("04"
    "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296"
    "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")

def recv_record(c):
    h = b""
    while len(h) < 5:
        d = c.recv(5 - len(h))
        if not d:
            return None
        h += d
    n = (h[3] << 8) | h[4]
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d:
            return None
        b += d
    return h + b

def server_hello(rnd, sid, suite, exts):
    hb = b"\x03\x03" + rnd + bytes([len(sid)]) + sid + suite.to_bytes(2, "big") + b"\x00" \
         + len(exts).to_bytes(2, "big") + exts
    hs = b"\x02" + len(hb).to_bytes(3, "big") + hb
    return b"\x16\x03\x03" + len(hs).to_bytes(2, "big") + hs

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(4)
print("ready", flush=True)
out = open(log, "a")
# A mode is group:suite:sid (sid "same" or "other"). ":switch" answers the
# second ClientHello with a ServerHello naming 0x1303 whatever the retry named.
# "plain:sid" answers with a ServerHello and an x25519 share rather than a
# retry, and "short" with a ServerHello record that declares more than it holds.
for mode in modes:
    parts = mode.split(":")
    c, _ = s.accept()
    c.settimeout(20)
    try:
        r1 = recv_record(c)
        body = r1[9:]
        sid = body[35:35 + body[34]]
        if parts[-1] == "other":
            sid = bytes(len(sid))
        if parts[0] == "short":
            c.sendall(b"\x16\x03\x03\x00\x08\x02\xff\xff\xff\x03\x03\x00\x00")
        elif parts[0] == "plain":
            ks = b"\x00\x33\x00\x24\x00\x1d\x00\x20" + bytes(range(1, 33))
            c.sendall(server_hello(bytes(range(32)), sid, 0x1301, bytes.fromhex("002b00020304") + ks))
        if parts[0] in ("short", "plain"):
            out.write("aborted\n" if recv_record(c) is None else "read on\n")
            out.flush()
            c.close()
            continue
        group, suite = int(parts[0], 16), int(parts[1], 16)
        switch = len(parts) > 3
        exts = bytes.fromhex("002b00020304") + b"\x00\x33\x00\x02" + group.to_bytes(2, "big")
        c.sendall(server_hello(MAGIC, sid, suite, exts))
        r2 = recv_record(c)
        if r2 is None:
            out.write("aborted\n")
        elif r2[0] == 22 and r2[5] == 1 and switch:
            ks = b"\x00\x33" + (4 + len(P256_G)).to_bytes(2, "big") + group.to_bytes(2, "big") \
                 + len(P256_G).to_bytes(2, "big") + P256_G
            c.sendall(server_hello(bytes(range(32)), sid, 0x1303, bytes.fromhex("002b00020304") + ks))
            out.write("aborted\n" if recv_record(c) is None else "read on\n")
        elif r2[0] == 22 and r2[5] == 1:
            out.write("answered\n")
        else:
            out.write("record %d\n" % r2[0])
    except Exception as e:
        out.write("aborted\n" if isinstance(e, ConnectionError) else "timed out\n")
    out.flush()
    c.close()
PY
HRRP=8142
set -- "001d:1303:same" "the group the first ClientHello already sent a share for" "cannot answer" aborted \
       "0017:1302:same" "TLS_AES_256_GCM_SHA384, which was never offered" "cannot answer" aborted \
       "0017:1305:same" "TLS_AES_128_CCM_8_SHA256, which was never offered" "cannot answer" aborted \
       "0017:1301:other" "a session id the client did not send" "cannot answer" aborted \
       "0019:1301:same" "secp521r1, which was never listed" "cannot answer" aborted \
       "0017:1301:same:switch" "a ServerHello naming another suite than its retry" "different cipher suite" aborted \
       "plain:other" "a ServerHello echoing a session id the client did not send" "does not echo" aborted \
       "short" "a ServerHello whose length runs past its record" "could not accept" aborted \
       "0017:1301:same" "and the control: a retry this client can answer" "" answered
modes=""; k=1
while [ "$k" -le $# ]; do eval "modes=\"\$modes \${$k}\""; k=$((k + 4)); done
python3 "$tmp/hrr.py" $HRRP "$tmp/hrr.log" $modes > "$tmp/hrr.out" 2>&1 &
echo $! > "$tmp/hrr.pid"
i=0
while [ "$i" -lt 50 ]; do grep -q ready "$tmp/hrr.out" 2>/dev/null && break; i=$((i + 1)); sleep 0.2; done
printf 'b = get("https://127.0.0.1:%s/", true)\nif b == none\n    out("NONE")\n' "$HRRP" > "$tmp/hrr.w"
if ! grep -q ready "$tmp/hrr.out" 2>/dev/null; then bad "the HelloRetryRequest server" "did not start"
elif ! "$WORD" build "$tmp/hrr.w" -o "$tmp/hrrc" >/dev/null 2>&1; then bad "the HelloRetryRequest client" "build failed"
else
  n=0
  while [ $# -ge 4 ]; do
    n=$((n + 1))
    got=$(timeout 60 "$tmp/hrrc" 2>"$tmp/hrr.err"); rc=$?
    # the server writes its line once the client is gone, which may be a moment
    # after the client has returned
    i=0
    until [ "$i" -ge 50 ] || { [ -f "$tmp/hrr.log" ] && [ "$(wc -l < "$tmp/hrr.log" | tr -d ' ')" -ge "$n" ]; }; do
      i=$((i + 1)); sleep 0.2
    done
    srv=$(sed -n "${n}p" "$tmp/hrr.log" 2>/dev/null)
    if [ "$got" != NONE ] || [ "$rc" != 0 ]; then bad "$2" "got [$got] rc=$rc want [NONE]"
    elif [ "$srv" != "$4" ]; then bad "$2" "the server says the client $srv, want $4"
    elif [ -n "$3" ] && ! grep -q "$3" "$tmp/hrr.err"; then bad "$2" "no reason on stderr: [$(head -1 "$tmp/hrr.err")]"
    else ok "$2"; fi
    shift 4
  done
fi
kill "$(cat "$tmp/hrr.pid")" 2>/dev/null; rm -f "$tmp/hrr.pid"

echo
echo "== interim responses come first, and the answer is the one after them =="
run "103 Early Hints, then the response" "hello" 30 <<W
out(get("http://127.0.0.1:$PORT/early"))
W

run "100 and 102, then the response" "world" 30 <<W
out(get("http://127.0.0.1:$PORT/interims"))
W

run "a 101 the client never asked for is a failure" NONE 30 <<W
b = get("http://127.0.0.1:$PORT/switch")
if b == none
    out("NONE")
else
    out("GOT " . b)
W

echo
echo "== a response with no body ends with its head, whatever length it names =="
# Each of these holds the socket open after the head. Reading for the named
# length used to wait out the 30 s idle deadline, and the 10 s cap checks that
# it doesn't now.
run "HEAD, answered with a large Content-Length" "0" 10 <<W
out(len(head("http://127.0.0.1:$PORT/headhold")))
W

run "204 No Content with a Content-Length" "0" 10 <<W
out(len(get("http://127.0.0.1:$PORT/nocontent")))
W

run "304 Not Modified with a Content-Length" "0" 10 <<W
out(len(get("http://127.0.0.1:$PORT/notmodified")))
W

echo
echo "== a Content-Length that is not a length is a failed request, never a fault =="
run "a length of thirty digits" NONE 30 <<W
b = get("http://127.0.0.1:$PORT/hugelength")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

run "digits followed by letters" NONE 30 <<W
b = get("http://127.0.0.1:$PORT/badlength")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

run "a declared length past the ceiling is refused at the head" NONE 10 <<W
b = get("http://127.0.0.1:$PORT/overceiling")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

echo
echo "== a chunk size that is not a size fails the request when it arrives =="
# The server holds the socket open after the bad size line. Reading on used to
# wait out the 30 s idle deadline, and the 10 s cap checks that it doesn't now.
run "a chunk size line that is not hex" NONE 10 <<W
b = get("http://127.0.0.1:$PORT/badchunk")
if b == none
    out("NONE")
else
    out("GOT " . len(b) . " BYTES")
W

echo
echo "== the request carries what the URL says, and nothing a URL could smuggle in =="
run "Host names a port that is not the default" "GET /echo HTTP/1.1|Host: 127.0.0.1:$PORT|" 30 <<W
out(get("http://127.0.0.1:$PORT/echo"))
W

run "a query with no path is asked of /, not taken for the host" "GET /?x=y HTTP/1.1" 30 <<W
b = get("http://127.0.0.1:$PORT?x=y")
if b == none
    out("NONE")
else
    out(copy(b, 0, find(b, "|")))
W

run "the fragment is cut from the query" "GET /echo?x=y HTTP/1.1" 30 <<W
b = get("http://127.0.0.1:$PORT/echo?x=y#frag")
out(copy(b, 0, find(b, "|")))
W

run "a fragment is never sent" "GET /echo HTTP/1.1" 30 <<W
b = get("http://127.0.0.1:$PORT/echo#section")
out(copy(b, 0, find(b, "|")))
W

run "CR and LF in a URL refuse the request before it is sent" "NONE" 30 <<W
b = get("http://127.0.0.1:$PORT/echo" . char(13) . char(10) . "X-Evil:yes" . char(13) . char(10) . char(13) . char(10) . "GET /second")
if b == none
    out("NONE")
else
    out("SENT " . b)
W

run "a code point past ASCII is sent percent-encoded, not as its low byte" "GET /echo%C4%8D%C4%8AX-Evil:yes HTTP/1.1" 30 <<W
b = get("http://127.0.0.1:$PORT/echo" . char(269) . char(266) . "X-Evil:yes")
out(copy(b, 0, find(b, "|")))
W

run "a port too long to be a number is a malformed URL, not an overflow" NONE 30 <<W
b = get("http://127.0.0.1:999999999999999999999999999999/echo")
if b == none
    out("NONE")
W

run "a text body is sent as its UTF-8 bytes" "POST /echo HTTP/1.1|Host: 127.0.0.1:$PORT|4172c3a9" 30 <<W
out(post("http://127.0.0.1:$PORT/echo", "Ar" . char(233)))
W

echo
echo "test_net_limits: $pass passed, $fail failed"
[ "$fail" = 0 ]
