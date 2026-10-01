#!/bin/sh
# test_random.sh: random() fails closed.
#
# random() takes eight bytes from the operating system (getrandom on Linux,
# BCryptGenRandom on Windows, getentropy on macOS). It used to ignore a failure:
# the buffer was zeroed first, so random() answered 0, and under `net`, where
# every key share, client random and nonce comes from random(), a TLS handshake
# ran on secrets that were all zeros. Old kernels without getrandom and
# sandboxes that deny it both exist, and a program can't detect either itself.
#
# nogetrandom.py runs the program under a seccomp filter that fails getrandom,
# and each case asks for randomness. The answer has to be a located fault on
# both targets, and a fetch has to stop before it sends a byte. The controls
# are a program that asks for no randomness, which the filter must not affect,
# and random() with nothing filtered.
#
# Linux only (seccomp). python3 installs the filter.
# No `set -e`: the cases are meant to exit 70.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
cd "$root"
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "test_random: SKIP (seccomp is Linux's)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "test_random: SKIP (no python3)"; exit 0; }
NOGR="python3 $here/nogetrandom.py"

tmp=$(mktemp -d)
cleanup() { [ -f "$tmp/srv.pid" ] && kill "$(cat "$tmp/srv.pid")" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU="";; esac

printf 'out(random() >= 0)\n' > "$tmp/r.w"
printf 'out(1)\n' > "$tmp/quiet.w"
"$WORD" build "$tmp/r.w" -o "$tmp/r" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }
"$WORD" build "$tmp/quiet.w" -o "$tmp/quiet" >/dev/null 2>&1 || { echo "FAIL: build"; exit 1; }

# Where seccomp isn't available (nogetrandom.py exits 3), skip instead of
# failing every case below.
got=$($NOGR "$tmp/quiet" 2>&1); rc=$?
if [ "$rc" = 3 ]; then echo "test_random: SKIP (seccomp is not available here: $got)"; exit 0; fi

# expect <label> <want-rc> <want-substring> <cmd...>
expect() { label=$1; wrc=$2; want=$3; shift 3
  got=$(timeout 30 "$@" 2>&1 </dev/null); rc=$?
  case "$got" in *"$want"*) m=1;; *) m=0;; esac
  if [ "$rc" = "$wrc" ] && [ "$m" = 1 ]; then ok "$label"
  else bad "$label" "rc=$rc want $wrc, output [$got] want [$want]"; fi; }

echo "== the controls =="
expect "random() with the OS source working" 0 "true" "$tmp/r"
expect "a program that asks for no randomness runs under the filter" 0 "1" $NOGR "$tmp/quiet"

echo
echo "== no randomness: a located fault, never a zero =="
expect "getrandom answers ENOSYS" 70 "r.w:1: random: the operating system gave no random bytes" $NOGR "$tmp/r"
expect "getrandom answers EPERM" 70 "r.w:1: random: the operating system gave no random bytes" env NOGR_ERRNO=1 $NOGR "$tmp/r"
if [ -n "$QEMU" ]; then
  "$WORD" build -arm64 "$tmp/r.w" -o "$tmp/ra" >/dev/null 2>&1 || bad "arm64 build" "failed"
  expect "arm64: the OS source working" 0 "true" $QEMU "$tmp/ra"
  expect "arm64: getrandom answers ENOSYS" 70 "r.w:1: random: the operating system gave no random bytes" $NOGR "$(command -v $QEMU)" "$tmp/ra"
fi

echo
echo "== and a TLS handshake stops before it sends a byte =="
# A listener that accepts and records how many bytes arrive. The client makes
# its key share first thing after connecting, so with no entropy it must fault
# there, with nothing sent, instead of offering a key built on zeros.
cat > "$tmp/srv.py" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(4)
print("ready", flush=True)
while True:
    c, _ = s.accept()
    c.settimeout(10)
    got = b""
    try:
        while True:
            b = c.recv(4096)
            if not b:
                break
            got += b
    except Exception:
        pass
    with open(sys.argv[2], "ab") as f:
        f.write(b"%d\n" % len(got))
    c.close()
PY
# Its own port: test_net_limits uses 8139, and the two can run at the same time.
PORT=8143
python3 "$tmp/srv.py" $PORT "$tmp/seen" > "$tmp/srv.out" 2>&1 &
echo $! > "$tmp/srv.pid"
i=0
while [ "$i" -lt 50 ]; do grep -q ready "$tmp/srv.out" 2>/dev/null && break; i=$((i+1)); sleep 0.2; done
printf 'b = get("https://127.0.0.1:%s/")\nout(b == none)\n' "$PORT" > "$tmp/tls.w"
"$WORD" build "$tmp/tls.w" -o "$tmp/tls" >/dev/null 2>&1 || bad "tls build" "failed"
expect "an https fetch with no entropy faults" 70 "random: the operating system gave no random bytes" $NOGR "$tmp/tls"
sleep 1
if [ "$(cat "$tmp/seen" 2>/dev/null)" = "0" ]; then ok "and the server received nothing"
else bad "and the server received nothing" "the listener saw [$(cat "$tmp/seen" 2>/dev/null)] bytes per connection"; fi

echo
echo "test_random: $pass passed, $fail failed"
[ "$fail" = 0 ]
