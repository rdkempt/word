#!/bin/sh
# test_sockets.sh: the four socket primitives (connect, send, recv and close
# from the sys module) over loopback, on x86-64 and, under qemu, arm64, from one
# source. DNS, TLS and HTTP sit on top of them. A small Python server replies
# "PONG\n" to each connection, and a second one never answers a handshake,
# which connect() gives up on at its deadline.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "test_sockets: SKIP (no python3 for the loopback server)"; exit 0; }

tmp=$(mktemp -d)
SRV=""
HOLE=""
cleanup() { for p in $SRV $HOLE; do kill "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT

# The server's output goes to /dev/null. A background process that inherits the
# caller's stdout keeps that pipe open after this script exits, and a CI runner
# waits for EOF on it before the step can finish.
python3 - >/dev/null 2>&1 <<'PY' &
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 51987))
s.listen(16)
while True:
    try:
        c, _ = s.accept()
        c.recv(64)
        c.sendall(b"PONG\n")
        c.close()
    except Exception:
        pass
PY
SRV=$!

# A second peer that never finishes a handshake: a listener that fills its own
# accept queue. Linux drops a SYN it has no room for, so a client retransmits
# until its own deadline, and connect() has to give up at ten seconds instead
# of the kernel's two minutes. A system that refuses the connection instead
# proves nothing about the deadline, so socket_test.w is told about this peer
# only once a probe has found it silent.
python3 - >/dev/null 2>&1 <<'PY' &
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 51988))
s.listen(0)
held = []
for _ in range(2):
    c = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    c.setblocking(False)
    c.connect_ex(("127.0.0.1", 51988))
    held.append(c)
time.sleep(3600)
PY
HOLE=$!

# Wait for the server to be accepting before the client tries to connect.
i=0
while [ "$i" -lt 50 ]; do
  if python3 -c "import socket; socket.create_connection(('127.0.0.1',51987),0.3).close()" 2>/dev/null; then break; fi
  i=$((i+1)); sleep 0.1
done

# And for the silent peer to go silent: refused until it listens, open until
# its queue is full, and then a connect that times out. The second probe waits
# five seconds, since a client that retries a refused handshake (Windows does,
# twice) reports the refusal about two seconds in.
probe() { python3 -c "
import socket
s = socket.socket()
s.settimeout($1)
try:
    s.connect(('127.0.0.1', 51988))
    print('open')
except socket.timeout:
    print('silent')
except OSError:
    print('refused')
" 2>/dev/null || true; }
silent=""
i=0
while [ "$i" -lt 20 ]; do
  if [ "$(probe 1)" = silent ]; then
    [ "$(probe 5)" = silent ] && silent=51988
    break
  fi
  i=$((i+1)); sleep 0.2
done
[ -n "$silent" ] || echo "  (no peer here leaves a handshake unanswered: the connect deadline is not checked)"

fail=0
if ! "$WORD" build "$here/socket_test.w" -o "$tmp/sock" >"$tmp/err" 2>&1; then
  echo "  FAIL: x86-64 build"; sed 's/^/    /' "$tmp/err"; fail=1
else
  rc=0; "$tmp/sock" $silent || rc=$?; [ "$rc" = 0 ] || fail=1
fi

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
# An arm64 host runs the arm64 build natively only if it is Linux: that build is
# a Linux ELF, and on a Mac the host build above already is the arm64 run.
case "$(uname -s)/$(uname -m)" in Linux/aarch64|Linux/arm64) QEMU=" ";; esac
if [ -n "$QEMU" ]; then
  if ! "$WORD" build -arm64 "$here/socket_test.w" -o "$tmp/sock.a64" >"$tmp/err" 2>&1; then
    echo "  FAIL: arm64 build"; sed 's/^/    /' "$tmp/err"; fail=1
  else
    rc=0; $QEMU "$tmp/sock.a64" $silent > "$tmp/a64.txt" 2>&1 || rc=$?
    sed 's/^/  arm64: /' "$tmp/a64.txt"
    [ "$rc" = 0 ] || fail=1
  fi
fi

[ "$fail" = 0 ] || { echo "test_sockets: FAIL"; exit 1; }
echo "test_sockets: PASS"
