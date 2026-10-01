#!/bin/sh
# test_tls_server.sh: the net client against a local openssl s_server with a
# generated chain: ECDSA and RSA leaves, directly under the root and through an
# intermediate, the HelloRetryRequest paths and a CertificateRequest. Then
# plain http:// against a local server.
#
# Every live HTTPS test used to go through a proxy that re-signed with an RSA
# leaf, which hid a total failure against ECDSA leaves, what most of the web
# serves.
#
# openssl is a test tool only, never needed to build or run word. The suite
# adds its throwaway root to the system trust store, so it skips unless it can
# write the store (run it as root), and it puts the bundle back on any exit.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
[ -x ./word ] || { echo "FAIL: no ./word binary"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "test_tls_server: SKIP (no openssl)"; exit 0; }

BUNDLE=/etc/ssl/certs/ca-certificates.crt
[ -w "$BUNDLE" ] || { echo "test_tls_server: SKIP (cannot write $BUNDLE, run as root)"; exit 0; }

tmp=$(mktemp -d); pass=0; fail=0
# `word run` builds a temporary binary under $TMPDIR; keep it inside this
# script's own directory rather than in shared /tmp.
export TMPDIR="$tmp"
restore() {
  [ -f "$tmp/bundle.bak" ] && cp "$tmp/bundle.bak" "$BUNDLE"
  [ -n "$SPID" ] && kill $SPID 2>/dev/null
  rm -rf "$tmp"
}
trap restore EXIT INT TERM
cp "$BUNDLE" "$tmp/bundle.bak"

ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }

# ---- a throwaway root, intermediate, and leaves -----------------------------
cd "$tmp"
openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 2 \
  -subj "/O=word test/CN=word test root" -sha256 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -keyout int.key -out int.csr \
  -subj "/O=word test/CN=word test intermediate" 2>/dev/null
printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n' > int.ext
openssl x509 -req -in int.csr -CA root.crt -CAkey root.key -CAcreateserial -out int.crt \
  -days 2 -sha256 -extfile int.ext 2>/dev/null
printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n' > leaf.ext

openssl ecparam -name prime256v1 -genkey -noout -out ec.key 2>/dev/null
openssl req -new -key ec.key -out ec.csr -subj "/CN=127.0.0.1" 2>/dev/null
openssl x509 -req -in ec.csr -CA root.crt -CAkey root.key -CAcreateserial -out ec_direct.crt -days 2 -sha256 -extfile leaf.ext 2>/dev/null
openssl x509 -req -in ec.csr -CA int.crt  -CAkey int.key  -CAcreateserial -out ec_chain.crt  -days 2 -sha256 -extfile leaf.ext 2>/dev/null

openssl req -new -newkey rsa:2048 -nodes -keyout rsa.key -out rsa.csr -subj "/CN=127.0.0.1" 2>/dev/null
openssl x509 -req -in rsa.csr -CA root.crt -CAkey root.key -CAcreateserial -out rsa_direct.crt -days 2 -sha256 -extfile leaf.ext 2>/dev/null

cat root.crt >> "$BUNDLE"

cat > fetch.w <<'WEOF'
import net
b = get("https://127.0.0.1:4443/")
if b == none
    out("FAILED")
else
    out("OK")
WEOF

cd "$root"
./word build "$tmp/fetch.w" -o "$tmp/fetch" >/dev/null 2>&1 || { echo "FAIL: could not build the fetcher"; exit 1; }

# ---- one case: start a server, fetch, compare -------------------------------
# The fetch is expected to say OK unless a sixth argument says otherwise.
case_run() {
  label="$1"; cert="$2"; key="$3"; chain="$4"; extra="$5"; want="${6:-OK}"
  cd "$tmp"
  if [ -n "$chain" ]; then
    openssl s_server -accept 4443 -cert "$cert" -key "$key" -cert_chain "$chain" -tls1_3 $extra -www >/dev/null 2>&1 &
  else
    openssl s_server -accept 4443 -cert "$cert" -key "$key" -tls1_3 $extra -www >/dev/null 2>&1 &
  fi
  SPID=$!
  sleep 2
  got=$(cd "$root" && timeout 25 "$tmp/fetch" 2>/dev/null | head -1)
  kill $SPID 2>/dev/null; SPID=""
  sleep 1
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "got [$got] want [$want]"; fi
}

echo "== TLS 1.3 against a real server (local openssl) =="
case_run "ECDSA P-256 leaf, signed directly by the root" ec_direct.crt ec.key ""
case_run "ECDSA P-256 leaf via an intermediate (what real sites serve)" ec_chain.crt ec.key int.crt
case_run "RSA-2048 leaf, signed directly by the root" rsa_direct.crt rsa.key ""

# ---- HelloRetryRequest ------------------------------------------------------
# The ClientHello carries one key_share, for X25519, while advertising all
# three groups: making a keypair in every group used to be 98% of the
# handshake's CPU. A server that wants a group we sent no key for answers with a
# HelloRetryRequest, and that path is easy to get wrong: the transcript is
# rewritten (RFC 8446 4.4.1 replaces ClientHello1 with a synthetic
# message_hash), a cookie has to come back unchanged, and a mistake only shows
# up at Finished. `-groups` sets what the server accepts, which forces the
# retry.
echo
echo "== HelloRetryRequest (the server wants a group we sent no key_share for) =="
case_run "server insists on P-256: retry, and the chain still verifies" ec_chain.crt ec.key int.crt "-groups P-256"
case_run "server insists on P-384: retry (and P-384 ECDHE end to end)" ec_chain.crt ec.key int.crt "-groups P-384"
case_run "a stateless server: the HelloRetryRequest cookie is echoed back" ec_chain.crt ec.key int.crt "-groups P-256 -stateless"
# ...and a server that takes X25519 completes without a retry, the path most
# servers take.
case_run "server offers X25519: no retry needed" ec_chain.crt ec.key int.crt "-groups X25519"

# ---- CertificateRequest -----------------------------------------------------
# A server that asks for a client certificate puts a CertificateRequest in its
# flight, and that message is in the transcript its CertificateVerify signs, so
# here a transcript that leaves it out fails verification. The insecure fetches
# in test_net_verbs.sh can't see that. This client has no certificate and
# answers with an empty one (RFC 8446 4.4.2): a server that makes it optional
# carries on, one that requires it refuses with certificate_required (116), and
# both answer at once. Each used to wait out the 30 s idle deadline, which the
# 25 s cap in case_run reports as a failure.
echo
echo "== CertificateRequest (the server asks for a client certificate) =="
case_run "optional: an ECDSA chain verifies over a transcript with the request in it" ec_chain.crt ec.key int.crt "-verify 1"
case_run "optional: an RSA leaf verifies the same way" rsa_direct.crt rsa.key "" "-verify 1"
case_run "required: the empty Certificate is refused, and at once" ec_chain.crt ec.key int.crt "-Verify 1" FAILED

# ---- and the second ClientHello has to be the first one again ---------------
# RFC 8446 4.1.2: after a HelloRetryRequest the client sends the same
# ClientHello again, changing only key_share, cookie, early_data,
# pre_shared_key and padding. The random and the legacy_session_id aren't on
# that list.
#
# word used to make fresh ones, and every case above passed anyway, because
# openssl's server doesn't check. Microsoft's front end does: bing.com,
# office.com, live.com and msn.com ask for P-256 by retry, and all four
# answered illegal_parameter (test_top_sites.sh found it). So a passing
# handshake proves nothing here. This case keeps the server's -msg log and
# compares the two ClientHellos byte for byte where they have to match.
hellos_of() { # hellos_of <msg.log>: one line of hex per ClientHello received
  awk '
    /ClientHello/ { c = 1; buf = ""; next }
    /^[<>]/       { if (c) { print buf; c = 0 }; next }
    c             { gsub(/[^0-9a-f]/, "", $0); buf = buf $0 }
    END           { if (c) print buf }
  ' "$1"
}

echo
echo "== the retry's ClientHello is the first one again (RFC 8446 4.1.2) =="
cd "$tmp"
openssl s_server -accept 4443 -cert ec_chain.crt -key ec.key -cert_chain int.crt \
  -tls1_3 -groups P-256 -www -msg >msg.log 2>&1 &
SPID=$!
sleep 2
got=$(cd "$root" && timeout 25 "$tmp/fetch" 2>/dev/null | head -1)
kill $SPID 2>/dev/null; SPID=""
sleep 1
hellos_of msg.log > hellos.txt
nh=$(grep -c . hellos.txt || true)
# The identity bytes: legacy_version(2) is at 4, so the random is bytes 6..37,
# the session id length is byte 38 and the id itself 39..70, which is hex
# characters 13 through 142 of the message.
h1=$(sed -n 1p hellos.txt | cut -c13-142)
h2=$(sed -n 2p hellos.txt | cut -c13-142)
if [ "$got" != OK ]; then
  bad "the retry handshake completes" "got [$got] want [OK]"
elif [ "$nh" != 2 ]; then
  bad "the server saw two ClientHellos" "it logged $nh"
elif [ -z "$h1" ] || [ ${#h1} -ne 130 ]; then
  bad "the first ClientHello decodes" "got ${#h1} hex characters of identity, want 130"
elif [ "$h1" = "$h2" ]; then
  ok "the retry repeats the first random and legacy_session_id"
else
  bad "the retry repeats the first random and legacy_session_id" \
      "hello 1 $h1 != hello 2 $h2"
fi
cd "$root"

# ---- plain http over the same resolver + connect ---------------------------
# http:// and https:// share one path to the server, dns_resolve and connect()
# in net_fetch. They used to be separate copies that had drifted apart (only
# one handled a dotted quad). These cover the shared path directly.
echo
echo "== plain HTTP against a local server (shared resolver + connect) =="
mkdir -p "$tmp/www"; printf 'hello from a plain http server\n' > "$tmp/www/index.html"
( cd "$tmp/www" && python3 -m http.server 4480 --bind 127.0.0.1 >/dev/null 2>&1 & echo $! > "$tmp/http.pid" )
sleep 2
cat > "$tmp/h_ip.w" <<'WEOF'
import net
b = get("http://127.0.0.1:4480/index.html")
if b == none
    out("FAILED")
else
    out(len(b))
WEOF
cat > "$tmp/h_dead.w" <<'WEOF'
import net
b = get("http://127.0.0.1:9/")
if b == none
    out("REFUSED")
else
    out("BODY")
WEOF
cd "$root"
got=$(./word run "$tmp/h_ip.w" 2>/dev/null | head -1)
if [ "$got" = 31 ]; then ok "http:// to a dotted quad with an explicit port"
else bad "http dotted quad + port" "got [$got] want [31]"; fi

got=$(./word run "$tmp/h_dead.w" 2>/dev/null | head -1)
if [ "$got" = REFUSED ]; then ok "a refused TCP connect returns 0, not a bogus fd"
else bad "refused connect" "got [$got] want [REFUSED]"; fi
[ -f "$tmp/http.pid" ] && kill "$(cat "$tmp/http.pid")" 2>/dev/null

# https:// to a dead port must fail the same way (connect() answers 0).
cat > "$tmp/s_dead.w" <<'WEOF'
import net
b = get("https://127.0.0.1:9/")
if b == none
    out("REFUSED")
else
    out("BODY")
WEOF
got=$(./word run "$tmp/s_dead.w" 2>/dev/null | head -1)
if [ "$got" = REFUSED ]; then ok "https:// to a refused port returns 0"
else bad "https refused connect" "got [$got] want [REFUSED]"; fi

echo
echo "test_tls_server: $pass passed, $fail failed"
[ "$fail" = 0 ]
