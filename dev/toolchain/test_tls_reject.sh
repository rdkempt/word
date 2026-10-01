#!/bin/sh
# test_tls_reject.sh: the certificates word must refuse.
#
# test_tls_server.sh checks that good chains are accepted, and a client that
# accepts everything passes all of it. This is the other half: chains that are
# correctly signed but not legitimate, each served by a real openssl s_server.
#
# The first case, N1, is a non-CA intermediate. Before path validation, word
# checked each signature in the chain and nothing else, so any ordinary
# end-entity certificate (which anyone can get for a domain they own) could
# sign a certificate for any other name, and word believed it. openssl calls
# that "error 79: invalid CA certificate". It's an authentication bypass.
#
# N9 to N11 are the same kind of bug, in the two rules about extensions: word
# read each extension's critical flag and threw it away, and never looked at
# extendedKeyUsage. So a chain carrying a critical extension word couldn't
# process connected anyway, and so did one its issuer had marked for client
# authentication only. N12 is the leaf's own keyUsage, which word checked only
# on issuers: a leaf allowed keyEncipherment and not digitalSignature still
# authenticated a TLS 1.3 server, which it does by signing.
#
# Six positive controls come first, because a client that rejects everything
# passes every must-reject case. Both directions have to hold.
#
# openssl is a test tool only, never needed to build or run word. The suite
# adds a throwaway root to the system trust store, so it skips unless it can
# write the store (run it as root), and it puts the bundle back on any exit.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
cd "$root"
[ -x ./word ] || { echo "FAIL: no ./word binary"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "test_tls_reject: SKIP (no openssl)"; exit 0; }
BUNDLE=/etc/ssl/certs/ca-certificates.crt
[ -w "$BUNDLE" ] || { echo "test_tls_reject: SKIP (cannot write $BUNDLE, run as root)"; exit 0; }

tmp=$(mktemp -d); pass=0; fail=0
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

cd "$tmp"
LEAF='basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1'

# ---- roots -----------------------------------------------------------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout root.key -out root.crt -days 2 \
  -subj "/O=word test/CN=word reject root" -sha256 2>/dev/null
# a second trusted root that permits no intermediates at all (pathlen:0)
printf '[v3]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n' > p0.cnf
openssl req -x509 -newkey rsa:2048 -nodes -keyout p0.key -out p0.crt -days 2 \
  -subj "/O=word test/CN=word pathlen0 root" -sha256 -extensions v3 -config p0.cnf 2>/dev/null
# an untrusted root, never added to the bundle
openssl req -x509 -newkey rsa:2048 -nodes -keyout un.key -out un.crt -days 2 \
  -subj "/O=word test/CN=word untrusted root" -sha256 2>/dev/null

mkca() { # mkca <name> <ext-lines> <ca-crt> <ca-key> [days]
  printf '%s\n' "$2" > "$1.ext"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/O=word test/CN=$1" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA "$3" -CAkey "$4" -CAcreateserial \
    -out "$1.crt" -days "${5:-2}" -sha256 -extfile "$1.ext" 2>/dev/null
}
mkleaf() { # mkleaf <name> <ca-crt> <ca-key> [days] [san]
  printf '%s\n' "${5:-$LEAF}" > "$1.ext"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=127.0.0.1" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA "$2" -CAkey "$3" -CAcreateserial \
    -out "$1.crt" -days "${4:-2}" -sha256 -extfile "$1.ext" 2>/dev/null
}

# An expired certificate, made with explicit dates instead of a negative -days.
#
# -days means "how long from now", and older OpenSSL versions only accepted a
# negative one by accident. On a newer one it failed to make the certificate at
# all, so there was no chain to reject. `openssl ca` with -startdate and
# -enddate says what's meant, and it's what the not-yet-valid case below uses
# too.
mkdated() { # mkdated <name> <ca-crt> <ca-key> <startdate> <enddate> <ext-lines>
  printf '%s\n' "$6" > "$1.ext"
  openssl req -new -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" \
    -subj "/CN=127.0.0.1" 2>/dev/null
  mkdir -p "ca.d.$1" && touch "ca.d.$1/index" && echo 01 > "ca.d.$1/serial"
  printf '[ca]\ndefault_ca=c\n[c]\ndatabase=ca.d.%s/index\nserial=ca.d.%s/serial\nnew_certs_dir=ca.d.%s\ndefault_md=sha256\npolicy=p\nunique_subject=no\n[p]\ncommonName=supplied\n' "$1" "$1" "$1" > "ca.$1.cnf"
  openssl ca -batch -config "ca.$1.cnf" -cert "$2" -keyfile "$3" -in "$1.csr" \
    -out "$1.crt" -startdate "$4" -enddate "$5" -extfile "$1.ext" >/dev/null 2>&1
  [ -s "$1.crt" ] || { echo "FAIL: could not mint the expired fixture $1: openssl ca refused"; exit 1; }
}
PS=$(date -u -d "-60 days" +%Y%m%d%H%M%SZ); PE=$(date -u -d "-30 days" +%Y%m%d%H%M%SZ)

# proper intermediate, and the leaves under it
mkca int 'basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign' root.crt root.key
mkleaf good int.crt int.key
mkleaf direct root.crt root.key

# N1: an ordinary CA:FALSE leaf used as an intermediate (the bypass)
mkleaf attacker root.crt root.key 2 'basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:attacker.test'
mkleaf forged attacker.crt attacker.key

# N2: a CA whose keyUsage omits keyCertSign
mkca nosign 'basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature' root.crt root.key
mkleaf undernosign nosign.crt nosign.key

# N3 / N4: leaf out of date
mkdated expired int.crt int.key "$PS" "$PE" "$LEAF"
openssl req -new -newkey rsa:2048 -nodes -keyout future.key -out future.csr -subj "/CN=127.0.0.1" 2>/dev/null
printf '%s\n' "$LEAF" > future.ext
mkdir -p ca.d && touch ca.d/index && echo 01 > ca.d/serial
printf '[ca]\ndefault_ca=c\n[c]\ndatabase=ca.d/index\nserial=ca.d/serial\nnew_certs_dir=ca.d\ndefault_md=sha256\npolicy=p\n[p]\ncommonName=supplied\n' > ca.cnf
FS=$(date -u -d "+30 days" +%Y%m%d%H%M%SZ); FE=$(date -u -d "+60 days" +%Y%m%d%H%M%SZ)
openssl ca -batch -config ca.cnf -cert int.crt -keyfile int.key -in future.csr -out future.crt \
  -startdate "$FS" -enddate "$FE" -extfile future.ext >/dev/null 2>&1 || true

# N5: an expired intermediate, with an in-date leaf under it
mkdated oldint root.crt root.key "$PS" "$PE" 'basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign'
mkleaf underoldint oldint.crt oldint.key

# N6: the name does not match
mkleaf wronghost int.crt int.key 2 'basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:not-this-host.test'

# N7: chains only to a root we do not trust
mkleaf untrusted un.crt un.key

# N8: pathlen:0 root, but an intermediate below it
mkca p0int 'basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign' p0.crt p0.key
mkleaf underp0 p0int.crt p0int.key
mkleaf directp0 p0.crt p0.key

# N9, N10 and N11: the two extension rules, end to end.
#
# Each chain is correctly signed by a trusted root and in date. What's wrong is
# what the certificate says about itself. openssl refuses N9 with error 34
# ("unhandled critical extension") and N10 with error 26 ("unsuitable
# certificate purpose").
#
# test_x509_profile.sh covers the same rules at the verifier, with a much wider
# matrix and a second oracle. These three are here because an attacker meets a
# TLS 1.3 handshake with a real server, not the verifier on its own, and the
# refusal has to happen at that layer too.

# N9: a leaf carrying a critical extension the client does not process
mkleaf critext int.crt int.key 2 'basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1
1.3.6.1.4.1.99999.1=critical,DER:04:05:68:65:6c:6c:6f'

# N10: a leaf its issuer marked for client authentication and nothing else
mkleaf clientonly int.crt int.key 2 'basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,clientAuth
subjectAltName=IP:127.0.0.1'

# N11: the same critical extension, one link up
mkca critint 'basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign
1.3.6.1.4.1.99999.1=critical,DER:04:05:68:65:6c:6c:6f' root.crt root.key
mkleaf undercritint critint.crt critint.key

# N12: a leaf whose keyUsage allows key encipherment and not signing. TLS 1.3
# authenticates the server with a signature made by the leaf's key, and RFC 8446
# 4.4.2.2 requires digitalSignature wherever keyUsage is present. openssl's own
# `-purpose sslserver` would accept this chain (it also covers TLS 1.2's RSA key
# exchange), and the openssl server here serves it.
mkleaf encipheronly int.crt int.key 2 'basicConstraints=CA:FALSE
keyUsage=critical,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1'

# P6: the same unknown extension, not critical. RFC 5280 says a consumer that
# doesn't recognize a non-critical extension must ignore it, so this control
# keeps N9's fix from turning into "refuse anything unfamiliar".
mkleaf unkext int.crt int.key 2 'basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1
1.3.6.1.4.1.99999.1=DER:04:05:68:65:6c:6c:6f'

cat int.crt root.crt > introot.pem
cat root.crt >> "$BUNDLE"
cat p0.crt   >> "$BUNDLE"

cat > f.w <<'W'
b = get("https://127.0.0.1:4443/")
if b == none
    out("REJECTED")
else
    out("ACCEPTED")
W
cd "$root"; ./word build "$tmp/f.w" -o "$tmp/f" >/dev/null 2>&1 || { echo "FAIL: could not build the fetcher"; exit 1; }

case_run() { # case_run <want> <label> <cert> <key> [chain]
  want="$1"; label="$2"; cert="$3"; key="$4"; chain="$5"
  cd "$tmp"
  [ -f "$cert" ] || { bad "$label" "fixture $cert was not generated"; return; }
  if [ -n "$chain" ]; then
    openssl s_server -accept 4443 -cert "$cert" -key "$key" -cert_chain "$chain" -tls1_3 -www >/dev/null 2>&1 &
  else
    openssl s_server -accept 4443 -cert "$cert" -key "$key" -tls1_3 -www >/dev/null 2>&1 &
  fi
  SPID=$!
  sleep 2
  got=$(cd "$root" && timeout 25 "$tmp/f" 2>/dev/null | head -1)
  kill $SPID 2>/dev/null; SPID=""
  sleep 1
  if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "got [$got] want [$want]"; fi
}

echo "== positive controls (a client that rejects everything must fail these) =="
case_run ACCEPTED "valid leaf via a valid intermediate" good.crt good.key int.crt
case_run ACCEPTED "valid leaf issued directly by the root" direct.crt direct.key
case_run ACCEPTED "pathlen:0 root issuing a leaf directly is still fine" directp0.crt directp0.key
# Servers often send their own trust anchor in the chain (RFC 8446 lets them
# leave it out), and whether openssl does here depends on the runner's trust
# store, which is how this once passed locally and failed in CI. A self-signed
# certificate in the chain is a root, not an intermediate, so it mustn't use up
# a pathlen budget. Both shapes are pinned here.
case_run ACCEPTED "server also sends the root (pathlen:0, leaf direct)" directp0.crt directp0.key p0.crt
case_run ACCEPTED "server also sends the root (leaf via an intermediate)" good.crt good.key introot.pem
case_run ACCEPTED "unknown extension that is NOT critical is ignored" unkext.crt unkext.key int.crt

echo
echo "== chains that are correctly signed but must be refused =="
case_run REJECTED "N1 non-CA leaf used as an intermediate (authentication bypass)" forged.crt forged.key attacker.crt
case_run REJECTED "N2 intermediate whose keyUsage omits keyCertSign" undernosign.crt undernosign.key nosign.crt
case_run REJECTED "N3 expired leaf" expired.crt expired.key int.crt
case_run REJECTED "N4 leaf not yet valid" future.crt future.key int.crt
case_run REJECTED "N5 expired intermediate, in-date leaf" underoldint.crt underoldint.key oldint.crt
case_run REJECTED "N6 leaf whose SAN does not cover the host" wronghost.crt wronghost.key int.crt
case_run REJECTED "N7 chain to a root that is not in the trust store" untrusted.crt untrusted.key un.crt
case_run REJECTED "N8 intermediate beneath a pathlen:0 root" underp0.crt underp0.key p0int.crt
case_run REJECTED "N9 leaf with a critical extension the client cannot process" critext.crt critext.key int.crt
case_run REJECTED "N10 leaf whose extendedKeyUsage is clientAuth, not serverAuth" clientonly.crt clientonly.key int.crt
case_run REJECTED "N11 intermediate with a critical extension the client cannot process" undercritint.crt undercritint.key critint.crt
case_run REJECTED "N12 leaf whose keyUsage does not allow digitalSignature" encipheronly.crt encipheronly.key int.crt

echo
echo "test_tls_reject: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
