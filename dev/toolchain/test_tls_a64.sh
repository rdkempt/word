#!/bin/sh
# test_tls_a64.sh: TLS 1.3 handshakes run by arm64 code, over a real socket.
#
# test_crypto_w.sh runs the crypto and the handshake's known-answer vectors on
# arm64, and test_sockets.sh runs the socket primitives. This is where an arm64
# program completes handshakes with a server.
#
# One client is built for both targets, and both must give the same answers
# against a local openssl s_server: each suite the ClientHello offers, each
# group (x25519 on the first flight, P-256 and P-384 through a
# HelloRetryRequest), ECDSA leaves, a CertificateRequest, and the refusals
# SPEC 12.2 gives for a suite and a protocol version it doesn't speak. Then
# with verification on: a certificate nothing trusts, and, against a throwaway
# root added to the trust store, an RSA and an ECDSA leaf under it, an ECDSA
# leaf through an intermediate, and a good chain for another name. Those are
# the cases where arm64 code verifies a chain and the signature over the
# handshake, which it never reaches with verification off.
#
# The root goes into a private mount namespace, never into the host's store: a
# copy of the bundle net reads, with the root appended, is bind-mounted over it
# for this process tree only, with `unshare -m` as root (ci.yml runs the suite
# with sudo) or `unshare -Urm` unprivileged. Without either, those cases say
# they were skipped, and the rest still run.
#
# The arm64 half runs under qemu-user on an x86-64 host and natively on an arm64
# one, and the suite is the same either way. qemu-user emulates the instruction
# set and passes the network calls to the host, so under it this shows the
# arm64 code is right. openssl and qemu are test tools only, never needed to
# build or run word. Linux only: the arm64 client is a Linux ELF, and the trust
# store is a file there.
#
# Nothing here pipes into a helper, which would lose its counts in a subshell.
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
[ "$(uname -s)" = Linux ] || { echo "test_tls_a64: SKIP -- Linux only (the arm64 client is a Linux ELF)"; exit 0; }
command -v openssl >/dev/null 2>&1 || { echo "FAIL: this suite needs openssl for its server"; exit 1; }
QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -z "$QEMU" ]; then
  echo "test_tls_a64: SKIP -- no qemu-aarch64 and not an arm64 host, so there is no arm64 half to run"
  exit 0
fi
# Into a private mount namespace first, if there is one to be had (see above).
if [ -z "$TLS_A64_NS" ]; then
  if [ "$(id -u)" = 0 ] && unshare -m true 2>/dev/null; then
    TLS_A64_NS=root; export TLS_A64_NS; exec unshare -m sh "$0" "$@"
  elif unshare -Urm true 2>/dev/null; then
    TLS_A64_NS=user; export TLS_A64_NS; exec unshare -Urm sh "$0" "$@"
  fi
fi
tmp=$(mktemp -d); srv=""
trap '[ -n "$srv" ] && kill "$srv" 2>/dev/null; rm -rf "$tmp"' EXIT
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 60"
cd "$tmp" || exit 1

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok: $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1 -- $2"; }

# Two clients, which print the body (openssl's -www status page, which names
# the suite it chose) or NONE: `get` skips verification and `getv` keeps it on.
printf '%s\n' 'b = get(args()[1], true)' 'if b == none' '    out("NONE")' 'else' '    out(b)' > get.w
printf '%s\n' 'b = get(args()[1])' 'if b == none' '    out("NONE")' 'else' '    out(b)' > getv.w
for c in get getv; do
  "$WORD" build "$c.w" -o "$c.x86" > berr 2>&1 || { echo "FAIL: $c did not build: $(head -1 berr)"; exit 1; }
  "$WORD" build -arm64 "$c.w" -o "$c.a64" > berr 2>&1 || { echo "FAIL: $c did not build for arm64: $(head -1 berr)"; exit 1; }
  chmod +x "$c.x86" "$c.a64"
done

# Self-signed leaves for the cases with verification off, and a root, an
# intermediate and leaves under them (the shapes test_tls_server.sh uses) for
# the cases with it on. `other` is a good chain for 127.0.0.2, not 127.0.0.1.
mint() { # mint <name> <openssl req key arguments...>
  n=$1; shift
  openssl req -x509 -nodes -keyout "$n.key" -out "$n.crt" -days 2 -subj "/CN=127.0.0.1" \
    -addext "subjectAltName=IP:127.0.0.1" "$@" >/dev/null 2>&1 || { echo "FAIL: could not mint $n"; exit 1; }
}
mint ss_rsa  -newkey rsa:2048 -sha256
mint ss_p256 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -sha256
mint ss_p384 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -sha384
{
  openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 2 \
    -subj "/O=word test/CN=word a64 test root" -sha256 &&
  openssl req -new -newkey rsa:2048 -nodes -keyout int.key -out int.csr \
    -subj "/O=word test/CN=word a64 test intermediate" &&
  printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n' > int.ext &&
  openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial -out int.crt \
    -days 2 -sha256 -extfile int.ext &&
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n' > leaf.ext &&
  printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.2\n' > other.ext &&
  openssl ecparam -name prime256v1 -genkey -noout -out ec.key &&
  openssl req -new -key ec.key -out ec.csr -subj "/CN=127.0.0.1" &&
  openssl x509 -req -in ec.csr -CA root.crt -CAkey root.key -CAcreateserial -out ec_direct.crt -days 2 -sha256 -extfile leaf.ext &&
  openssl x509 -req -in ec.csr -CA int.crt -CAkey int.key -CAcreateserial -out ec_chain.crt -days 2 -sha256 -extfile leaf.ext &&
  openssl x509 -req -in ec.csr -CA root.crt -CAkey root.key -CAcreateserial -out ec_other.crt -days 2 -sha256 -extfile other.ext &&
  openssl req -new -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.csr -subj "/CN=127.0.0.1" &&
  openssl x509 -req -in rsa.csr -CA root.crt -CAkey root.key -CAcreateserial -out rsa_direct.crt -days 2 -sha256 -extfile leaf.ext
} > mintlog 2>&1 || { echo "FAIL: could not mint the chain: $(tail -1 mintlog)"; exit 1; }

# The store net reads (net_ca_paths' first choice), with the root added, for
# this namespace only.
BUNDLE=/etc/ssl/certs/ca-certificates.crt
trusted=0
if [ -n "$TLS_A64_NS" ] && [ -f "$BUNDLE" ]; then
  cat "$BUNDLE" root.crt > bundle.pem
  if mount --bind bundle.pem "$BUNDLE" 2>/dev/null; then trusted=1; fi
fi

# The listener is up once the kernel lists it. A probe connection would use up
# one of the server's two accepts.
listening() { p=$(printf '%04X' "$1"); grep -q ":$p 00000000:0000 0A" /proc/net/tcp 2>/dev/null; }

# answer <client binary> <url>: what one client made of it, which is the suite
# named on the page, "none", or what went wrong.
answer() {
  out=$($TO $QEMU_RUN "$1" "$2" 2>/dev/null); rc=$?
  if [ "$rc" -ge 128 ] 2>/dev/null; then echo "SIGNAL $rc"; return; fi
  if [ "$rc" != 0 ]; then echo "exit $rc"; return; fi
  if [ "$out" = NONE ]; then echo none; return; fi
  s=$(printf '%s\n' "$out" | grep -m1 -oE 'Cipher is [A-Z0-9_]+' | sed 's/Cipher is //')
  if [ -n "$s" ]; then echo "$s"; else echo "unexpected: $(printf '%s' "$out" | head -1 | cut -c1-50)"; fi
}

port=48300
# hs <want> <label> <client> <cert> <key> [s_server arguments...]: one server,
# the x86-64 client and then the arm64 one against it, each held to <want>.
hs() {
  want=$1; lab=$2; cl=$3; crt=$4; key=$5; shift 5; port=$((port + 1))
  openssl s_server -accept "127.0.0.1:$port" -www -naccept 2 -cert "$crt" -key "$key" "$@" >/dev/null 2>&1 &
  srv=$!
  i=0; while [ $i -lt 100 ] && ! listening "$port"; do sleep 0.05; i=$((i + 1)); done
  QEMU_RUN=""; ax=$(answer "./$cl.x86" "https://127.0.0.1:$port/")
  QEMU_RUN=$QEMU; aa=$(answer "./$cl.a64" "https://127.0.0.1:$port/")
  kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; srv=""
  if [ "$ax" = "$want" ] && [ "$aa" = "$want" ]; then ok "$lab [$want on both]"
  else bad "$lab" "x86-64 [$ax], arm64 [$aa], want [$want] on both"; fi
}
CC=TLS_CHACHA20_POLY1305_SHA256; AG=TLS_AES_128_GCM_SHA256

echo "== the two suites the ClientHello offers (verification off) =="
hs $CC "the client's first choice"                  get ss_rsa.crt ss_rsa.key -tls1_3
hs $AG "AES-128-GCM when it is all the server has"  get ss_rsa.crt ss_rsa.key -tls1_3 -ciphersuites $AG
echo "== the three groups: x25519 on the first flight, P-256 and P-384 by HelloRetryRequest =="
hs $CC "x25519"                                     get ss_rsa.crt ss_rsa.key -tls1_3 -groups X25519
hs $CC "P-256, after a HelloRetryRequest"           get ss_rsa.crt ss_rsa.key -tls1_3 -groups P-256
hs $AG "P-384 after a retry, with the other suite"  get ss_rsa.crt ss_rsa.key -tls1_3 -groups P-384 -ciphersuites $AG
echo "== ECDSA servers, P-256 and P-384 (verification off) =="
hs $CC "an ECDSA P-256 leaf"                        get ss_p256.crt ss_p256.key -tls1_3
hs $CC "an ECDSA P-384 leaf"                        get ss_p384.crt ss_p384.key -tls1_3
echo "== what SPEC 12.2 says does not connect is refused, as none =="
hs none "a server with only TLS_AES_256_GCM_SHA384" get ss_rsa.crt ss_rsa.key -tls1_3 -ciphersuites TLS_AES_256_GCM_SHA384
hs none "a TLS 1.2-only server"                     get ss_rsa.crt ss_rsa.key -tls1_2
hs none "a certificate nothing trusts, with verification on" getv ss_p256.crt ss_p256.key -tls1_3
# A server that asks for a client certificate gets an empty one (RFC 8446
# 4.4.2), so where it's optional the handshake completes. Where it's required
# the answer is none either way. test_net_verbs.sh checks that it comes at once
# and not at the idle deadline; here both targets have to reach it without a
# fault.
echo "== a CertificateRequest is answered with an empty Certificate =="
hs $CC "optional client certificate (-verify 1)"    get ss_p256.crt ss_p256.key -tls1_3 -verify 1
hs none "required client certificate (-Verify 1)"   get ss_p256.crt ss_p256.key -tls1_3 -Verify 1

echo "== verification on: the chain, and the signature over the handshake =="
skipped=""
if [ "$trusted" = 1 ]; then
  hs $CC "an RSA leaf under the root"                getv rsa_direct.crt rsa.key -tls1_3
  hs $CC "an ECDSA leaf under the root"              getv ec_direct.crt ec.key -tls1_3
  hs $AG "an ECDSA leaf through an intermediate"     getv ec_chain.crt ec.key -tls1_3 -cert_chain int.crt -ciphersuites $AG
  hs none "a good chain, for another name"           getv ec_other.crt ec.key -tls1_3
  # The server's CertificateVerify signs a transcript with the request in it,
  # so this is the one where leaving it out fails verification.
  hs $CC "a chain verified over a CertificateRequest" getv ec_chain.crt ec.key -tls1_3 -cert_chain int.crt -verify 1
else
  skipped=" (5 verified-chain cases skipped: no private mount namespace to add a root in; run as root, or allow unprivileged user namespaces)"
  echo "  SKIP: the verified-chain cases$skipped"
fi

echo
echo "test_tls_a64: $pass passed, $fail failed$skipped"
[ "$fail" = 0 ]
