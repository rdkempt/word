#!/bin/sh
# test_win_netconf.sh: on Windows, `net` asks the OS for its resolver and its
# trust anchors, and takes neither from a Unix path.
#
# A Unix absolute path isn't an error on Windows: "/etc/resolv.conf" is
# \etc\resolv.conf on the current drive, and any signed-in user can create a
# directory at the root of C: (icacls C:\ grants Authenticated Users "AD"). The
# net library used to read /etc/resolv.conf and six PEM bundles there, before
# the Crypt32 ROOT store, so any user could pick the resolver and the whole
# trust store of every word program run from C:. With no such file (the usual
# case), lookups went to the 1.1.1.1 fallback instead of the adapter's
# resolver, so internal names and localhost didn't resolve. `word version` also
# read /proc/self/exe as its own bytes.
#
# What this checks, natively:
#
#   1. The resolver dns_server() picks is one the host has configured
#      (Get-DnsClientServerAddress lists them), and 1.1.1.1 only when the host
#      has none.
#   2. localhost resolves: dns_resolve answers 127.0.0.1 itself, and a fetch of
#      localhost, and of a name under it, reaches a server on the loopback.
#   3. None of that changes when the current drive's root holds
#      \etc\resolv.conf, all six PEM bundles and \proc\self\exe: the same
#      resolver, the same number of trust anchors, the same `word version`. The
#      suite checks that the planted files can be read at those paths from
#      there, so the case can't pass by planting nothing.
#
# The drive is a `subst` of a temporary directory, not C:\ itself. A test suite
# shouldn't create directories at the root of the system drive, and a mapped
# drive shows the same thing: a leading slash names the root of whichever drive
# is current.
#
# Windows only; anywhere else it skips. powershell (to list the host's
# resolvers) and python3 (the loopback server) are only test tools, never
# needed to build or run word. No `set -e`: a failed case is counted, not
# fatal.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) echo "test_win_netconf: SKIP (Windows only: the paths in question are drive-relative there)"; exit 0 ;;
esac
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
WORD=$(wordbin "${WORD:-$root/word.exe}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(hostpath "$(mktemp -d)"); pass=0; fail=0; drive=""
# subst takes X: and /D, and MSYS would rewrite both on the way to it.
nopc() { MSYS2_ARG_CONV_EXCL='*' "$@"; }
cleanup() {
  [ -f "$tmp/srv.pid" ] && kill "$(cat "$tmp/srv.pid")" 2>/dev/null
  [ -n "$drive" ] && nopc subst "$drive:" /D >/dev/null 2>&1
  # Out of $tmp first: Windows will not remove a directory a process is in.
  cd /
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }
field() { printf '%s\n' "$1" | sed -n "s/^$2 //p"; }

# The probe asks net itself: dns_server, dns_resolve and net_load_roots are the
# net library's own functions, and they're in the program because it calls
# get(). `seen` reports what a Unix path holds from the current directory,
# which is how the drive-root case shows its planted files were there to read.
cat > "$tmp/probe.w" <<'W'
dotted(ip)
    if kind(ip) == "number"
        return "none"
    return "" . ip[0] . "." . ip[1] . "." . ip[2] . "." . ip[3]

seen(p)
    b = read(p)
    if kind(b) == "none"
        return "-"
    return "" . len(b)

a = args()
if len(a) > 1
    b = get(a[1])
    if b == none
        out("NONE")
    else
        out(b)
else
    out("server " . dotted(dns_server()))
    out("localhost " . dotted(dns_resolve("localhost")))
    out("roots " . len(net_load_roots()))
    out("resolv.conf " . seen("/etc/resolv.conf"))
    out("bundle " . seen("/etc/ssl/certs/ca-certificates.crt"))
W
"$WORD" build "$tmp/probe.w" -o "$tmp/probe.exe" > "$tmp/err" 2>&1 || {
  echo "FAIL: could not build the probe:"; sed 's/^/  /' "$tmp/err"; exit 1; }

# Everything below runs the probe from $tmp, on the system drive where nothing
# is planted, except the drive-root case.
cd "$tmp"
base=$("$tmp/probe.exe")
server=$(field "$base" server)
roots=$(field "$base" roots)

echo "== the resolver is the one the host has configured =="
if ! command -v powershell >/dev/null 2>&1; then
  bad "the host's resolvers" "no powershell to ask Get-DnsClientServerAddress"
else
  oracle=$(powershell -NoProfile -NonInteractive -Command \
    'Get-DnsClientServerAddress -AddressFamily IPv4 | ForEach-Object { $_.ServerAddresses }' \
    2>/dev/null | tr -d '\r' | sed '/^$/d' | sort -u)
  if [ -z "$oracle" ]; then
    if [ "$server" = 1.1.1.1 ]; then ok "the host names no IPv4 resolver, and 1.1.1.1 stands"
    else bad "the host names no IPv4 resolver" "dns_server() said $server rather than 1.1.1.1"; fi
  elif printf '%s\n' "$oracle" | grep -qxF "$server"; then
    ok "dns_server() is $server, a resolver this host has configured"
  else
    bad "dns_server() is [$server]" "the host's IPv4 resolvers are: $(echo $oracle)"
  fi
fi

echo
echo "== localhost is the loopback address (RFC 6761) =="
lh=$(field "$base" localhost)
if [ "$lh" = 127.0.0.1 ]; then ok "dns_resolve(\"localhost\") is 127.0.0.1"
else bad "dns_resolve(\"localhost\")" "got [$lh]"; fi

if command -v python3 >/dev/null 2>&1; then
  mkdir -p "$tmp/www"
  printf 'hello from the loopback' > "$tmp/www/hi.txt"
  PORT=$(python3 -c "import socket; s = socket.socket(); s.bind(('127.0.0.1', 0)); print(s.getsockname()[1])")
  ( cd / && exec python3 -m http.server --bind 127.0.0.1 --directory "$tmp/www" "$PORT" ) > "$tmp/srv.out" 2>&1 &
  echo $! > "$tmp/srv.pid"
  i=0
  while [ $i -lt 50 ]; do
    python3 -c "import socket; socket.create_connection(('127.0.0.1', $PORT), 1)" 2>/dev/null && break
    sleep 0.2; i=$((i+1))
  done
  for h in localhost app.localhost; do
    got=$("$tmp/probe.exe" "http://$h:$PORT/hi.txt" 2>&1)
    if [ "$got" = "hello from the loopback" ]; then ok "http://$h:$PORT/ reaches the loopback server"
    else bad "http://$h:$PORT/" "got [$got]"; fi
  done
else
  echo "  SKIP: no python3 for a loopback server (dns_resolve's own answer above still counts)"
fi

echo
echo "== nothing at the root of the current drive is read =="
# Every path net_ca_paths lists, read from the compiler's source so this file
# doesn't keep a second copy of the list.
capaths=$(sed -n '/^net_ca_paths()/,/^$/p' "$root/compiler/word.w" \
          | sed -n 's/^ *p\[[0-9]*\] = "\(.*\)"$/\1/p')
[ -n "$capaths" ] || bad "net_ca_paths" "is not where this expects it in compiler/word.w"
mkdir -p "$tmp/root/etc" "$tmp/root/proc/self"
printf 'nameserver 192.0.2.53\n' > "$tmp/root/etc/resolv.conf"
printf 'planted' > "$tmp/root/proc/self/exe"
# A self-signed certificate made for this suite, whose key was thrown away. It
# parses, so a store that read the bundle would hold this one anchor and no
# other.
cat > "$tmp/planted.pem" <<'PEM'
-----BEGIN CERTIFICATE-----
MIIB0jCCAXegAwIBAgIUF/Zs3sDehNfwTxw82EvSsBkgu/owCgYIKoZIzj0EAwIw
PTE7MDkGA1UEAwwyd29yZCB0ZXN0X3dpbl9uZXRjb25mIHBsYW50ZWQgcm9vdCAo
bm90IGFuIGFuY2hvcikwIBcNMjYwOTIyMTgyODI4WhgPMjEyNjA4MjkxODI4Mjha
MD0xOzA5BgNVBAMMMndvcmQgdGVzdF93aW5fbmV0Y29uZiBwbGFudGVkIHJvb3Qg
KG5vdCBhbiBhbmNob3IpMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYqWHvL9P
Ujn2LyPZ1zMlSzUX+QpSM0jSnEVYgWp77fGpmbstJxhsdjLtBnxWX4gBOJzDbrdT
oTK4z+T8hkbHV6NTMFEwHQYDVR0OBBYEFEeHz0Itawa9OqAUpdH+L9aQhSnoMB8G
A1UdIwQYMBaAFEeHz0Itawa9OqAUpdH+L9aQhSnoMA8GA1UdEwEB/wQFMAMBAf8w
CgYIKoZIzj0EAwIDSQAwRgIhAMnATlFySCgCZtTRMhyZgz2ZEF+6+U1C7ylzmLfz
sIDKAiEAqiIA3wlauMJduLVpLW4o7zgS9CV4ncWU98gDkSiG/dI=
-----END CERTIFICATE-----
PEM
for p in $capaths; do
  mkdir -p "$(dirname "$tmp/root$p")"
  cp "$tmp/planted.pem" "$tmp/root$p"
done

for l in W V U T S R Q P O N M L K J I H G F; do
  if nopc subst "$l:" "$(cygpath -w "$tmp/root")" >/dev/null 2>&1; then drive=$l; break; fi
done
if [ -z "$drive" ]; then
  bad "a drive to plant on" "no free letter for subst"
else
  dl=$(printf '%s' "$drive" | tr 'A-Z' 'a-z')
  echo "  (planted at the root of $drive:, a subst of a temporary directory)"
  planted=$(cd "/$dl/" && "$tmp/probe.exe")
  if [ "$(field "$planted" resolv.conf)" = - ] || [ "$(field "$planted" bundle)" = - ]; then
    bad "the planted files" "are not readable at /etc/... from $drive:\\, so this case would prove nothing"
  else
    ok "from $drive:\\, /etc/resolv.conf and /etc/ssl/certs/ca-certificates.crt are the planted files"
  fi

  got=$(field "$planted" server)
  if [ "$got" = "$server" ]; then ok "the resolver is still $server, not the planted 192.0.2.53"
  else bad "the resolver from $drive:\\" "got [$got], from the system drive [$server]"; fi

  got=$(field "$planted" localhost)
  if [ "$got" = 127.0.0.1 ]; then ok "localhost is still 127.0.0.1"
  else bad "localhost from $drive:\\" "got [$got]"; fi

  # The ROOT store fills on demand, so it can grow between two runs: the count
  # from the planted drive has to match one taken on either side of it.
  got=$(field "$planted" roots)
  after=$(field "$("$tmp/probe.exe")" roots)
  if [ "$roots" -gt 1 ] 2>/dev/null && { [ "$got" = "$roots" ] || [ "$got" = "$after" ]; }; then
    ok "the trust store is still the $got anchors of the ROOT store, not the planted bundle's one"
  else
    bad "the trust store from $drive:\\" "$got anchors, the ROOT store $roots (then $after)"
  fi

  mine=$("$WORD" version 2>/dev/null | sed -n 's/^  this binary *//p')
  there=$(cd "/$dl/" && "$WORD" version 2>/dev/null | sed -n 's/^  this binary *//p')
  if [ -n "$mine" ] && [ "$there" = "$mine" ]; then
    ok "word version fingerprints itself ($mine), not the planted \\proc\\self\\exe"
  else
    bad "word version from $drive:\\" "said [$there], from the system drive [$mine]"
  fi
fi

echo
echo "test_win_netconf: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
