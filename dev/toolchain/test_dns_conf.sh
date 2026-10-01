#!/bin/sh
# test_dns_conf.sh: the resolver comes from /etc/resolv.conf, and localhost is
# never sent to it.
#
# A compiled program has to see what the rest of the host sees: an internal
# zone, a split-horizon view, a loopback stub resolver. So dns_server() takes
# the first IPv4 `nameserver` line from /etc/resolv.conf, and only falls back
# to 1.1.1.1 when the file doesn't name one. That's Linux and macOS, where
# sys.nameservers() answers `none`. Windows lists its resolvers through an API
# and never reads the file (there it would be \etc\resolv.conf at the root of
# the current drive, which anyone can create). test_win_netconf.sh is the
# Windows half of this suite.
#
# localhost and every name under it are the loopback address (RFC 6761 6.3),
# answered by dns_resolve itself. The last section checks that: it runs a
# resolver of its own that logs every name it's asked, and requires that it
# never hears of localhost, while an ordinary name asked in the same run
# reaches it and gets its answer.
#
# What this checks is the address dns_server() settled on, not whether
# resolution works. Pointing resolv.conf at a black hole and watching a lookup
# fail doesn't work in a sandbox that answers UDP:53 for any destination: a
# wrong nameserver still resolves, and the test would pass without proving
# anything.
#
# It has to control /etc/resolv.conf, and it does that in a private mount
# namespace instead of editing the live system's copy. A test suite shouldn't
# change a running machine's resolver configuration, and in a container
# /etc/resolv.conf is usually a bind mount, so removing it fails with `Device
# or resource busy`.
#
# So it re-execs under `unshare -m` and mounts a tmpfs copy of /etc over /etc
# inside that namespace. Nothing outside the namespace sees a change, there's
# nothing to restore, and an interrupted run can't leave the machine without a
# resolver. The rest of /etc is copied in, so anything else the probe reads is
# still there.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
RC=/etc/resolv.conf

if [ "${WORD_DNS_NS:-0}" != "1" ]; then
  # A network namespace too, where we can get one: the localhost section runs
  # a resolver on the loopback, and in a fresh namespace nothing else listens
  # there and no query can leave.
  if command -v unshare >/dev/null 2>&1; then
    for nsflags in -mn -m; do
      if unshare $nsflags true >/dev/null 2>&1; then
        WORD_DNS_NS=1; WORD_DNS_NETNS=0
        [ "$nsflags" = -mn ] && WORD_DNS_NETNS=1
        export WORD_DNS_NS WORD_DNS_NETNS
        exec unshare $nsflags sh "$0" "$@"
      fi
    done
  fi
  echo "test_dns_conf: SKIP (needs 'unshare -m' to isolate /etc; run as root on Linux)"
  exit 0
fi

# Inside the namespace: make our mounts private, then shadow /etc with a copy.
mount --make-rprivate / >/dev/null 2>&1 || true
etccopy=$(mktemp -d)
mount -t tmpfs tmpfs "$etccopy" >/dev/null 2>&1 || {
  echo "test_dns_conf: SKIP (cannot mount a tmpfs inside the namespace)"; exit 0; }
cp -a /etc/. "$etccopy"/ >/dev/null 2>&1 || true
mount --bind "$etccopy" /etc >/dev/null 2>&1 || {
  echo "test_dns_conf: SKIP (cannot shadow /etc inside the namespace)"; exit 0; }

# On a systemd host /etc/resolv.conf is a symlink into /run
# (../run/systemd/resolve/stub-resolv.conf on Ubuntu), and `cp -a` copied it as
# a symlink. A mount namespace isolates mounts, not file contents, so every
# `> $RC` below would follow the link and overwrite the host's real resolver
# configuration. This used to happen on every CI run: the runner was left with
# no usable resolver and the job hung at the end until GitHub cancelled it.
#
# Removing the link makes the first `>` create a regular file in the tmpfs, and
# every write after it stays there.
rm -f "$RC"
[ -e "$RC" ] && {
  echo "test_dns_conf: SKIP (cannot clear $RC inside the namespace)"; exit 0; }

tmp=$(mktemp -d); pass=0; fail=0
cleanup() {
  [ -f "$tmp/resolver.pid" ] && kill "$(cat "$tmp/resolver.pid")" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

{ printf 'import sys\nimport fs\nimport net\n'; python3 "$root/dev/toolchain/netlib_cat.py" dns; cat "$here/dns/dns_probe.w"; } > "$tmp/app.w"
"$WORD" build "$tmp/app.w" -o "$tmp/probe" >"$tmp/err" 2>&1 || {
  echo "FAIL: could not build the probe:"; sed 's/^/  /' "$tmp/err"; exit 1; }

case_run() { # case_run <want> <label> <resolv.conf contents>
  want="$1"; label="$2"; body="$3"
  printf '%s' "$body" > "$RC"
  got=$("$tmp/probe" 2>/dev/null | sed -n 1p)
  lit=$("$tmp/probe" 2>/dev/null | sed -n 2p)
  if [ "$lit" != "203.0.113.9" ]; then
    echo "  FAIL: $label -- a dotted quad went to the resolver [$lit]"; fail=$((fail+1)); return
  fi
  if [ "$got" = "$want" ]; then echo "  ok: $label"; pass=$((pass+1))
  else echo "  FAIL: $label -- got [$got] want [$want]"; fail=$((fail+1)); fi
}

echo "== the resolver is taken from /etc/resolv.conf =="
case_run 1.2.3.4 "a plain nameserver line" 'nameserver 1.2.3.4
'
case_run 10.0.0.53 "the first of several wins" 'nameserver 10.0.0.53
nameserver 9.9.9.9
'
case_run 192.168.1.1 "comments and options are skipped" '# corporate resolver
; another comment style
options timeout:2 attempts:3
search example.internal
nameserver 192.168.1.1
'
case_run 8.8.4.4 "an IPv6 nameserver is passed over for the IPv4 one" 'nameserver 2001:4860:4860::8888
nameserver 8.8.4.4
'
case_run 127.0.0.53 "a loopback stub resolver is honoured" 'nameserver 127.0.0.53
'
case_run 172.16.0.1 "a tab after the keyword, and more space before the address" "nameserver	  172.16.0.1
"
# What follows the address is ignored, the way glibc ignores it. Each of these
# used to fall back to 1.1.1.1, so word asked Cloudflare while the host's other
# programs asked the resolver the file named.
case_run 10.9.8.7 "a trailing space after the address" "$(printf 'nameserver 10.9.8.7 \nsearch x\n')"
case_run 10.9.8.7 "a trailing tab after the address" "$(printf 'nameserver 10.9.8.7\t\nsearch x\n')"
case_run 10.9.8.7 "a comment after the address" 'nameserver 10.9.8.7 # office resolver
'
case_run 10.9.8.7 "a CRLF line ending" "$(printf 'nameserver 10.9.8.7\r\nsearch example.internal\r\n')"

echo
echo "== and 1.1.1.1 stands whenever it cannot be =="
case_run 1.1.1.1 "no nameserver line at all" 'search example.internal
options ndots:1
'
case_run 1.1.1.1 "an octet out of range leaves the default" 'nameserver 999.1.1.1
'
case_run 1.1.1.1 "a truncated address is not half-applied" 'nameserver 10.0.0
'
case_run 1.1.1.1 "an IPv6-only resolver" 'nameserver 2001:4860:4860::8888
'
case_run 1.1.1.1 "an empty file" ''
case_run 1.1.1.1 "a name that merely starts with nameserver" 'nameserverfoo 1.2.3.4
'
# resolv.conf(5): the keyword must start the line, and glibc's parser agrees
# (it never skips leading whitespace). An indented line isn't a nameserver
# line, and reading it as one would honour a directive the system resolver
# ignores.
case_run 1.1.1.1 "an indented line is not a directive" '   nameserver 172.16.0.1
'

# Removing the file can't be tested on a host where it's a bind mount. Inside
# the namespace it's an ordinary file on a tmpfs.
rm -f "$RC"
got=$("$tmp/probe" 2>/dev/null | sed -n 1p)
if [ "$got" = "1.1.1.1" ]; then echo "  ok: no /etc/resolv.conf at all"; pass=$((pass+1))
else echo "  FAIL: no /etc/resolv.conf at all -- got [$got] want [1.1.1.1]"; fail=$((fail+1)); fi

echo
echo "== localhost is never sent to the resolver (RFC 6761) =="
# The resolver resolv.conf names answers every A query with 192.0.2.99 and logs
# each name it's asked. An ordinary name comes back 192.0.2.99 and is in the
# log, which shows the probe uses that resolver. localhost and the names under
# it have to come back 127.0.0.1 and be missing from the log. If the probe sent
# localhost, the answer would be 192.0.2.99 and the name would be in the log,
# and either one fails.
#
# Port 53 needs root, or the fresh network namespace the re-exec above asks
# for. A loopback in a fresh namespace starts down.
[ "${WORD_DNS_NETNS:-0}" = 1 ] && ip link set lo up >/dev/null 2>&1
cat > "$tmp/resolver.py" <<'PY'
import socket, sys
log = open(sys.argv[1], "a")
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.77", 53))
open(sys.argv[2], "w").write("ready\n")
while True:
    q, peer = s.recvfrom(1500)
    if len(q) < 12:
        continue
    labels, p = [], 12
    while p < len(q) and q[p] != 0:
        labels.append(q[p + 1:p + 1 + q[p]].decode("ascii", "replace"))
        p += 1 + q[p]
    log.write(".".join(labels) + "\n")
    log.flush()
    # The question echoed, then one A record pointing back at it (0xc00c).
    head = q[:2] + b"\x81\x80\x00\x01\x00\x01\x00\x00\x00\x00"
    answer = b"\xc0\x0c\x00\x01\x00\x01\x00\x00\x00\x3c\x00\x04" + bytes([192, 0, 2, 99])
    s.sendto(head + q[12:p + 5] + answer, peer)
PY
python3 "$tmp/resolver.py" "$tmp/asked" "$tmp/ready" 2>"$tmp/resolver.err" &
echo $! > "$tmp/resolver.pid"
i=0
while [ ! -s "$tmp/ready" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
if [ ! -s "$tmp/ready" ]; then
  echo "  SKIP: no resolver of our own on 127.0.0.77:53 (needs root or a network namespace):"
  sed 's/^/    /' "$tmp/resolver.err"
else
  printf 'nameserver 127.0.0.77\n' > "$RC"
  "$tmp/probe" example.test localhost api.localhost LOCALHOST. > "$tmp/answers" 2>/dev/null
  lh_case() { # lh_case <name> <want> <label>
    got=$(sed -n "s/^$1 //p" "$tmp/answers")
    if [ "$got" = "$2" ]; then echo "  ok: $3"; pass=$((pass+1))
    else echo "  FAIL: $3 -- $1 gave [$got] want [$2]"; fail=$((fail+1)); fi
  }
  lh_case example.test 192.0.2.99 "an ordinary name is asked of the resolver resolv.conf names"
  lh_case localhost 127.0.0.1 "localhost is 127.0.0.1"
  lh_case api.localhost 127.0.0.1 "a name under localhost is 127.0.0.1"
  lh_case LOCALHOST. 127.0.0.1 "so is LOCALHOST., in capitals and fully qualified"
  asked=$(tr '\n' ' ' < "$tmp/asked" | sed 's/ $//')
  if [ "$asked" = "example.test" ]; then
    echo "  ok: the resolver was asked for example.test and for nothing else"; pass=$((pass+1))
  else
    echo "  FAIL: the resolver was asked for [$asked], want example.test alone"; fail=$((fail+1))
  fi
fi

echo
echo "test_dns_conf: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
