#!/bin/sh
# test_fuzz_net.sh: fuzzing the DNS response parser and the HTTP response
# framing.
#
# test_fuzz.sh and test_fuzz_tls.sh cover the X.509 decoder and the TLS
# handshake. The other two parsers a remote party reaches had known-answer tests
# and no fuzzer: dns_parse_a, which reads a resolver's unauthenticated answer
# before any connection exists, and the HTTP response framing (the status line,
# the headers, Content-Length and chunked), which over http:// is all there is
# between a server and the caller. dns_conf_line gets the DNS inputs as well,
# as though each line were resolv.conf.
#
# For any bytes, every call has to return and answer something sensible, which
# dev/toolchain/fuzz/fuzz_net.w checks (it exits 1 when an answer isn't).
# Everything else fails: exit 70 is word's bounds check firing (a parser
# indexing past what arrived), 124 is a hang, and any other status is a crash,
# whether a signal above 128 or the 127 Git Bash reports for most Windows
# crashes. Every non-zero status counts as a failure.
#
# FUZZ_OFFSETS caps the truncations and corruptions per seed (default 160).
# windows.yml runs it lower, where a process costs twenty times what it does on
# Linux.
set -e
LC_ALL=C; export LC_ALL
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
WORD=$(wordbin "${WORD:-$root/word}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3 (mutation driver)"; exit 0; }
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 10"
OFFSETS=${FUZZ_OFFSETS:-160}

tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
{ printf 'import sys\n'
  python3 "$root/dev/toolchain/netlib_cat.py" dns http
  cat "$here/fuzz/fuzz_net.w"
} > "$tmp/app.w"
"$WORD" build "$tmp/app.w" -o "$tmp/probe" >"$tmp/err" 2>&1 || {
  echo "FAIL: could not build the probe:"; sed 's/^/  /' "$tmp/err"; exit 1; }

cases=0; bad=0
judge() { # judge <dns|http> <label> <file>
  rc=0; out=$($TO "$tmp/probe" "$1" "$3" 2>&1) || rc=$?
  cases=$((cases + 1))
  case "$rc" in
    0)   return 0 ;;
    1)   echo "  FAIL: $2 -- $(printf '%s' "$out" | tail -1)" ;;
    70)  echo "  FAIL: $2 -- FAULTED at exit 70: $(printf '%s' "$out" | tail -1)" ;;
    124) echo "  FAIL: $2 -- hung (10s)" ;;
    *)   if [ "$rc" -gt 128 ]; then echo "  FAIL: $2 -- signal $((rc - 128))"
         else echo "  FAIL: $2 -- exit $rc: $(printf '%s' "$out" | tail -1)"; fi ;;
  esac
  bad=$((bad + 1)); cp "$3" "$tmp/last_failure"
  return 0
}

# ---- seeds -----------------------------------------------------------------
# DNS: answers of every shape dns_parse_a has a branch for, each built the way a
# resolver builds it; and resolv.conf text, which the dns mode reads line by
# line. HTTP: each framing http_frame tells apart, interim heads, and the
# malformed lengths it has to refuse.
python3 - "$tmp" <<'PY'
import os, struct, sys
tmp = sys.argv[1]
d = os.path.join(tmp, "seed")
os.makedirs(d, exist_ok=True)

def name(host):
    return b"".join(bytes([len(l)]) + l for l in host.encode().split(b".")) + b"\x00"
def header(qd, an, flags=0x8180, ident=0x1234):
    return struct.pack(">HHHHHH", ident, flags, qd, an, 0, 0)
def question(host, qtype=1):
    return name(host) + struct.pack(">HH", qtype, 1)
def rr(owner, rtype, rdata, ttl=300):
    return owner + struct.pack(">HHIH", rtype, 1, ttl, len(rdata)) + rdata
PTR = b"\xc0\x0c"

dns = {
    "a":        header(1, 1) + question("example.com") + rr(PTR, 1, bytes([93, 184, 216, 34])),
    "cname":    header(1, 2) + question("www.example.com") + rr(PTR, 5, name("example.com"))
                + rr(b"\xc0\x2d", 1, bytes([10, 0, 0, 7])),
    "aaaa-a":   header(1, 2) + question("example.com") + rr(PTR, 28, bytes(16)) + rr(PTR, 1, bytes([1, 2, 3, 4])),
    "txt":      header(1, 1) + question("example.com", 16) + rr(PTR, 16, b"\x05hello"),
    "nxdomain": header(1, 0, 0x8183) + question("nope.example"),
    "two-q":    header(2, 1) + question("a.example") + question("b.example") + rr(PTR, 1, bytes([5, 6, 7, 8])),
    "long":     header(1, 1) + question(".".join(["a" * 63] * 3) + ".com") + rr(PTR, 1, bytes([9, 9, 9, 9])),
    "many":     header(1, 30) + question("example.com") + b"".join(rr(PTR, 1, bytes([10, 0, 0, i])) for i in range(30)),
    "self-ptr": header(1, 1) + question("example.com") + rr(b"\xc0\x0c", 5, b"\xc0\x0c") ,
    "conf":     b"# resolver\nnameserver 10.9.8.7 # office\nnameserver\t192.168.1.1\r\nsearch x\n",
}
http = {
    "length":   b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/plain\r\n\r\nhello",
    "chunked":  b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n1;ext=1\r\n,\r\n6\r\n world\r\n0\r\n\r\n",
    "trailer":  b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n3\r\nabc\r\n0\r\nX-Trailer: 1\r\n\r\n",
    "close":    b"HTTP/1.1 200 OK\r\nServer: x\r\n\r\nthe body runs to the close",
    "interim":  b"HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
    "switch":   b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nno",
    "nobody":   b"HTTP/1.1 204 No Content\r\nContent-Length: 100\r\n\r\n",
    "lists":    b"HTTP/1.1 200 OK\r\nContent-Length: 3, 3\r\nContent-Length: 3\r\nX-A:  b \r\n\r\nabcdef",
    "badlen":   b"HTTP/1.1 200 OK\r\nContent-Length: 999999999999999999999999999999\r\n\r\nabc",
    "te-cl":    b"HTTP/1.1 200 OK\r\nContent-Length: 99\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
    "bighex":   b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFF\r\nab\r\n0\r\n\r\n",
    "tiny":     b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + b"".join(b"1\r\n" + bytes([97 + i % 26]) + b"\r\n" for i in range(40)) + b"0\r\n\r\n",
}
for k, v in dns.items():
    open(os.path.join(d, "dns." + k), "wb").write(v)
for k, v in http.items():
    open(os.path.join(d, "http." + k), "wb").write(v)
PY
for f in "$tmp"/seed/*; do b=${f##*/}; judge "${b%%.*}" "seed $b" "$f"; done
echo "  ok: $cases seeds"

# ---- truncation and byte corruption ----------------------------------------
# Every prefix of each seed (spread out past OFFSETS of them), and OFFSETS
# copies with one to three bytes replaced by something a parser branches on:
# a CR or LF, a colon, a space, a digit or hex letter, a chunk extension's
# semicolon, a DNS compression pointer, a 63-byte label length, 0 and 0xff.
before=$cases
python3 - "$tmp" "$OFFSETS" <<'PY'
import os, random, sys, glob
tmp, want = sys.argv[1], int(sys.argv[2])
random.seed(20260923)
out = os.path.join(tmp, "mut")
os.makedirs(out, exist_ok=True)
poke = list(b"\r\n: 0123456789abcdefABCDEF;,") + [0x00, 0xff, 0xc0, 0x3f, 0x80, 0x0c]
n = 0
for f in sorted(glob.glob(os.path.join(tmp, "seed", "*"))):
    kind = os.path.basename(f).split(".")[0]
    b = open(f, "rb").read()
    step = max(1, len(b) // want)
    for k in list(range(0, len(b), step)):
        open(os.path.join(out, "%s.%05d" % (kind, n)), "wb").write(b[:k]); n += 1
    for _ in range(want):
        c = bytearray(b)
        for _ in range(random.randrange(1, 4)):
            c[random.randrange(len(c))] = random.choice(poke)
        open(os.path.join(out, "%s.%05d" % (kind, n)), "wb").write(bytes(c)); n += 1
# Shapes the pokes won't reach: a name that is all compression pointers, a
# count of answers far past what is there, a label running off the end, and on
# the HTTP side a size line with no end, thousands of one-byte chunks, thousands
# of headers, a head that never ends, thousands of interim heads before the
# answer, and nothing at all.
extra = {
    "dns": [b"\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00" + b"\xc0\x0c" * 2000,
            b"\x12\x34\x81\x80\x00\x01\xff\xff\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01",
            b"\x12\x34\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00\x3f" + b"a" * 20,
            b"", b"\x00" * 12, b"nameserver " + b"9" * 5000 + b"\n"],
    "http": [b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + b"1" * 100000,
             b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + b"1\r\nx\r\n" * 5000 + b"0\r\n\r\n",
             b"HTTP/1.1 200 OK\r\n" + b"X-A: b\r\n" * 5000 + b"Content-Length: 1\r\n\r\nz",
             b"HTTP/1.1 200 OK\r\nX-A: " + b"b" * 100000,
             b"HTTP/1.1 100 Continue\r\n\r\n" * 3000 + b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",
             b"", b"HTTP/1.1", b"\r\n\r\n", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0"],
}
for kind, blobs in extra.items():
    for e in blobs:
        open(os.path.join(out, "%s.%05d" % (kind, n)), "wb").write(e); n += 1
PY
for f in "$tmp"/mut/*; do b=${f##*/}; judge "${b%%.*}" "mutant $b" "$f"; done
echo "  ok: $((cases - before)) truncations, corruptions and structural cases"

echo "test_fuzz_net: $cases cases, $bad failures"
[ "$bad" = 0 ]
