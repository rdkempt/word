#!/bin/sh
# test_x509_profile.sh: the X.509 profile of SPEC 12.2, checked against two
# independent implementations on the same bytes.
#
# test_tls_reject.sh drives whole chains through a real openssl s_server, which
# answers "does the client refuse this connection" but needs root, changes the
# system trust store, and costs a process and a sleep per case. This asks the
# narrower question of what the verifier says about a chain, so it needs no
# root and no socket, doesn't touch the trust store, and can afford a wide
# matrix.
#
# Three implementations answer each case:
#
#   word     dev/toolchain/x509_verdict.w, built from the net library (netlib_cat.py)
#   openssl  openssl verify -purpose sslserver -verify_hostname
#   Go       dev/toolchain/x509_verdict.go, crypto/x509
#
# openssl and Go are test tools only, never needed to build or run word. Go's
# PKIX code shares no history with openssl's, so a case all three agree on is
# one that three independent readings of RFC 5280 agree on.
#
# Eleven cases in the matrix (D1 to D11) are divergences, where the three don't
# agree, and each records the verdict every implementation gives. A
# differential test that dropped the cases where the answers differ would stop
# being differential. SPEC 12.2 lists the six places word differs and why: in
# five, word refuses a chain another accepts, and in one (D3 and D4) it accepts
# a chain openssl refuses.
#
# The suite started with C1 and E1: a trusted, correctly signed chain carrying
# a critical extension word didn't process, and a trusted leaf whose
# extendedKeyUsage said clientAuth and not serverAuth. openssl refused both
# (error 34 "unhandled critical extension" and error 26 "unsuitable certificate
# purpose"). word accepted both, because it threw away the critical flag and
# never read extendedKeyUsage, so a certificate could be used for something it
# wasn't authorized for.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")

# And the conversion in the other direction has to be off. Git Bash rewrites an
# argument that looks like an absolute POSIX path into a Windows one before
# handing it to a native .exe, and openssl's -subj looks like one:
# `/O=word profile/CN=rootca` reached openssl.exe as `C:/Program Files/`, and it
# refused the whole fixture. Every path this script needs is converted
# explicitly, so the automatic rewrite could only break distinguished names
# here. On Linux and macOS these variables do nothing.
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
cd "$root"
WORD=$(wordbin "${WORD:-$root/word}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "test_x509_profile: SKIP (no openssl)"; exit 0; }

tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0; skipped_go=0

# Every openssl call below goes through this. Making a fixture is noisy even
# when it works (`req` reports progress on stderr). The output used to go to
# /dev/null, so when a fixture failed on a Windows runner, `set -e` ended the
# run with status 1 and no explanation. Now it's captured, and printed when the
# command fails.
ssl() { # ssl <what-it-was-for> <openssl args...>
  what=$1; shift
  if ! openssl "$@" >"$tmp/ssl.log" 2>&1; then
    echo "FAIL: openssl could not $what"
    echo "  openssl $*"
    sed 's/^/  | /' "$tmp/ssl.log"
    exit 1
  fi
}

ok()  { echo "  ok:   $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 -- $2"; fail=$((fail+1)); }

# ---- the word verifier, as a program ---------------------------------------
{ printf 'import sys\nimport fs\n'
  # pem too, because the driver's --store mode reads the platform's PEM bundle
  # the way net_load_roots reads it.
  python3 "$root/dev/toolchain/netlib_cat.py" sha256 sha512 bignum rsa ecdsa der x509 pem
  cat "$here/x509_verdict.w"
} > "$tmp/app.w"
if ! "$WORD" build "$tmp/app.w" -o "$tmp/wverdict" >"$tmp/buildlog" 2>&1; then
  echo "FAIL: could not build the word verdict driver:"; sed 's/^/  /' "$tmp/buildlog"; exit 1
fi

# ---- the Go verifier, as a program -----------------------------------------
# Built inside a throwaway module: a go.mod committed under dev/toolchain would
# make the repository look like a Go module to every tool that looks for one.
GOVERDICT=""
if command -v go >/dev/null 2>&1; then
  mkdir -p "$tmp/go" && cp "$here/x509_verdict.go" "$tmp/go/main.go"
  if ( cd "$tmp/go" && go mod init wordx509 >/dev/null 2>&1 \
       && go build -o "$tmp/goverdict" . >"$tmp/golog" 2>&1 ); then
    GOVERDICT="$tmp/goverdict"
  else
    echo "test_x509_profile: WARN (go is present but the oracle did not build)"
    sed 's/^/    /' "$tmp/golog"
  fi
else
  echo "test_x509_profile: note -- go is not installed, so the second oracle is skipped"
fi
[ -n "$GOVERDICT" ] || skipped_go=1

# ---- fixtures ----------------------------------------------------------------
cd "$tmp"
HOST=word.profile.test
# P-256 for speed, plus a few RSA chains, so both signature paths are covered by
# the positive controls and not only by the crypto KATs.
newkey() { ssl "generate a P-256 key" ecparam -name prime256v1 -genkey -noout -out "$1"; }
der()    { ssl "convert $1 to DER" x509 -in "$1.crt" -outform DER -out "$1.der"; }

# `-config` replaces the host's openssl.cnf instead of adding to it, so the file
# written here is the only one `req` reads, and it has to carry everything
# `req` looks up, the [req] section included. -subj means nothing is ever
# prompted for, but a config with no distinguished_name is still malformed, and
# how loudly openssl objects to that has changed between releases.
mkroot() { # mkroot <name> <ext-lines> [rsa]
  printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n[v3]\n%s\n' "$1" "$2" > "$1.cnf"
  if [ "$3" = rsa ]; then
    ssl "mint the RSA root $1" req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.crt" -days 2 \
      -subj "/O=word profile/CN=$1" -sha256 -extensions v3 -config "$1.cnf"
  else
    newkey "$1.key"
    ssl "mint the root $1" req -x509 -key "$1.key" -out "$1.crt" -days 2 \
      -subj "/O=word profile/CN=$1" -sha256 -extensions v3 -config "$1.cnf"
  fi
  der "$1"
}

mkcert() { # mkcert <name> <subject> <ext-lines> <issuer-name> [rsa]
  printf '%s\n' "$3" > "$1.ext"
  if [ "$5" = rsa ]; then
    ssl "request an RSA key for $1" req -new -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.csr" -subj "$2"
  else
    newkey "$1.key"
    ssl "request $1" req -new -key "$1.key" -out "$1.csr" -subj "$2"
  fi
  ssl "sign $1 with $4" x509 -req -in "$1.csr" -CA "$4.crt" -CAkey "$4.key" -CAcreateserial \
    -out "$1.crt" -days 2 -sha256 -extfile "$1.ext"
  der "$1"
}

CA=$(printf 'basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign')
LEAF=$(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s' "$HOST")
LEAFNOEKU=$(printf 'basicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nsubjectAltName=DNS:%s' "$HOST")

mkroot rootca "$CA"
mkroot rootrsa "$CA" rsa
mkroot untrusted "$CA"

# --- the ordinary, well-formed shapes (positive controls) --------------------
mkcert good       "/CN=$HOST"                  "$LEAF"      rootca
mkcert goodrsa    "/CN=$HOST"                  "$LEAF"      rootrsa rsa
mkcert inter      "/O=word profile/CN=inter"   "$CA
extendedKeyUsage=serverAuth,clientAuth"        rootca
mkcert viainter   "/CN=$HOST"                  "$LEAF"      inter
mkcert internoeku "/O=word profile/CN=internoeku" "$CA"     rootca
mkcert vianoeku   "/CN=$HOST"                  "$LEAF"      internoeku
mkcert noeku      "/CN=$HOST"                  "$LEAFNOEKU" rootca
mkcert wildcard   "/CN=wild"                   "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:*.profile.test"             rootca
mkcert unkncrit   "/CN=$HOST"                  "$LEAF
1.3.6.1.4.1.99999.1=DER:04:05:68:65:6c:6c:6f"  rootca

# --- C: critical extensions nothing here processes ---------------------------
mkcert critleaf "/CN=$HOST" "$LEAF
1.3.6.1.4.1.99999.1=critical,DER:04:05:68:65:6c:6c:6f" rootca
mkcert critint  "/O=word profile/CN=critint" "$CA
1.3.6.1.4.1.99999.1=critical,DER:04:05:68:65:6c:6c:6f" rootca
mkcert undercritint "/CN=$HOST" "$LEAF" critint

# --- E: extendedKeyUsage -------------------------------------------------------
mkcert ekucli   "/CN=$HOST" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,clientAuth
subjectAltName=DNS:$HOST" rootca
mkcert ekuclinc "/CN=$HOST" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
subjectAltName=DNS:$HOST" rootca
mkcert ekuocsp  "/CN=$HOST" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,OCSPSigning
subjectAltName=DNS:$HOST" rootca
mkcert ekuany   "/CN=$HOST" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,2.5.29.37.0
subjectAltName=DNS:$HOST" rootca
mkcert interekucli "/O=word profile/CN=interekucli" "$CA
extendedKeyUsage=critical,clientAuth" rootca
mkcert underekucli "/CN=$HOST" "$LEAF" interekucli

# --- N: name constraints, which word does not implement ----------------------
# RFC 5280 4.2.1.10 requires the extension to be critical, so refusing it is
# the fail-closed reading: a sub-CA is only safe to delegate to because of the
# constraint, and honouring the delegation while ignoring the constraint would
# be the worst answer. openssl and Go implement name constraints and so accept
# the satisfied case, divergence D2 below.
mkcert ncint      "/O=word profile/CN=ncint" "$CA
nameConstraints=critical,permitted;DNS:.profile.test" rootca
mkcert underncok  "/CN=$HOST" "$LEAF" ncint
mkcert ncintx     "/O=word profile/CN=ncintx" "$CA
nameConstraints=critical,excluded;DNS:.profile.test" rootca
mkcert underncbad "/CN=$HOST" "$LEAF" ncintx
# The same constraints not marked critical. RFC 5280 says a CA must mark them
# critical, but some constrained sub-CAs don't. word used to ignore a
# non-critical one, which accepted the excluded name below that openssl and Go
# both refuse. It refuses any certificate carrying one now.
mkcert ncintnc     "/O=word profile/CN=ncintnc" "$CA
nameConstraints=permitted;DNS:.profile.test" rootca
mkcert underncnc   "/CN=$HOST" "$LEAF" ncintnc
mkcert ncintxnc    "/O=word profile/CN=ncintxnc" "$CA
nameConstraints=excluded;DNS:.profile.test" rootca
mkcert underncbadnc "/CN=$HOST" "$LEAF" ncintxnc
mkcert pcint       "/O=word profile/CN=pcint" "$CA
policyConstraints=requireExplicitPolicy:0" rootca
mkcert underpc     "/CN=$HOST" "$LEAF" pcint

# --- V: the path validation every verifier shares ----------------------------
mkcert notca      "/CN=notca.profile.test" "basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:notca.profile.test" rootca
mkcert undernotca "/CN=$HOST" "$LEAF" notca
mkcert nosign     "/O=word profile/CN=nosign" "basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature" rootca
mkcert undernosign "/CN=$HOST" "$LEAF" nosign
mkcert wronghost  "/CN=other" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:not-this-host.profile.test" rootca
mkcert untrustedleaf "/CN=$HOST" "$LEAF" untrusted

# --- X: a cross-signed root sitting past the anchor --------------------------
# What real chains look like. A CA that has moved to a newer root keeps serving
# a copy of it signed by the older one, so clients whose store predates the new
# root can still build a path, and clients whose store has it stop before the
# copy. example.com sends this (the leaf, two intermediates, then "SSL.com TLS
# ECC Root CA 2022" issued by "AAA Certificate Services"), and so do google.com
# and cloudflare.com.
#
# `crossroot` is rootca's own name and key, signed by `other`: the same subject
# and the same public key as the anchor, with a different issuer and
# signature. Appending it to a chain that already reaches rootca must change
# nothing.
mkroot other "$CA"
ssl "request the cross-signature for rootca" req -new -key rootca.key -out crossroot.csr \
  -subj "/O=word profile/CN=rootca"
ssl "cross-sign rootca with other" x509 -req -in crossroot.csr -CA other.crt -CAkey other.key \
  -CAcreateserial -out crossroot.crt -days 2 -sha256 -extfile rootca.cnf -extensions v3
der crossroot

# --- K: keyUsage -------------------------------------------------------------
# The leaf's key signs the TLS 1.3 handshake, so a leaf that carries keyUsage
# has to allow digitalSignature (RFC 8446 4.4.2.2). The reported gap was an RSA
# leaf restricted to keyEncipherment, which is what a TLS 1.2 RSA key exchange
# wanted and which can't sign a CertificateVerify. openssl's `-purpose
# sslserver` still accepts it, because that purpose is shared with TLS 1.2, and
# Go doesn't read a leaf's keyUsage at all, so that case is divergence D5 below.
# A keyUsage with no bits in it is D6 and D7. K1 and K2 are the controls: a
# leaf that allows both, and a leaf with no keyUsage.
mkcert kuenc     "/CN=$HOST" "basicConstraints=CA:FALSE
keyUsage=critical,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$HOST" rootrsa rsa
mkcert kusigenc  "/CN=$HOST" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$HOST" rootrsa rsa
mkcert kunone    "/CN=$HOST" "basicConstraints=CA:FALSE
extendedKeyUsage=serverAuth
subjectAltName=DNS:$HOST" rootca
# A keyUsage that holds no bits at all: a BIT STRING of only its unused-bit
# count. RFC 5280 requires at least one bit, and word used to read it as no
# keyUsage (unrestricted), which on an intermediate skipped the keyCertSign
# rule.
mkcert kuemptyint "/O=word profile/CN=kuemptyint" "basicConstraints=critical,CA:TRUE
2.5.29.15=critical,DER:03:01:00" rootca
mkcert underkuempty "/CN=$HOST" "$LEAF" kuemptyint
mkcert kuemptyleaf "/CN=$HOST" "basicConstraints=CA:FALSE
2.5.29.15=critical,DER:03:01:00
extendedKeyUsage=serverAuth
subjectAltName=DNS:$HOST" rootca

# --- S: signatures made with a hash older than SHA-256 ---------------------
# Two different questions involve the same hash, and treating them as one lost
# a third of the Windows trust store.
#
# A signature on the path made with SHA-1 or MD5 is refused (rule 3): nothing
# here verifies those, so the link doesn't hold. D8 and D9 are those, with the
# divergences, because openssl still accepts them.
#
# A trust anchor's own self-signature isn't on the path. RFC 5280 6.1.1 makes
# the anchor an input to path validation, a name and a key the relying party
# already trusts, and neither openssl nor Go checks its self-signature. word
# used to refuse to parse such a certificate, which dropped the anchor from the
# store and then failed the sites whose chains needed it: 19 of 53 anchors in
# one Windows ROOT store, so example.com, cloudflare.com and others failed on
# Windows while working on Linux (whose PEM bundle also carries a newer
# self-signed root for each of those chains). S1, S2 and S3 are that case, from
# three directions.
#
# The same parse failure hit a certificate the peer sent past the anchor (rule
# 8, which gives it no vote): a server that included its own SHA-1 self-signed
# root made every chain it sent unparseable. That's S4.
#
# S5 is the control: a forged self-signed certificate with the anchor's name is
# refused by the signature check under the stored key.
#
# S6 is the anchor question again, for RSA-PSS. PSS parameters that leave out
# the hash mean SHA-1 (RFC 4055), and word refused to parse that certificate
# where it took a sha1WithRSAEncryption one, so a PSS root self-signed that way
# was dropped from the store while S1's root was kept.
mkoldroot() { # mkoldroot <name> <digest>: a root self-signed with an old hash
  printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=%s\n[v3]\n%s\n' "$1" "$CA" > "$1.cnf"
  ssl "mint the $2 root $1" req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.crt" \
    -days 2 -subj "/O=word profile/CN=$1" "-$2" -extensions v3 -config "$1.cnf"
  der "$1"
}

mkoldcert() { # mkoldcert <name> <subject> <ext-lines> <issuer> <digest>
  printf '%s\n' "$3" > "$1.ext"
  newkey "$1.key"
  ssl "request $1" req -new -key "$1.key" -out "$1.csr" -subj "$2"
  ssl "sign $1 with $4 over $5" x509 -req -in "$1.csr" -CA "$4.crt" -CAkey "$4.key" \
    -CAcreateserial -out "$1.crt" -days 2 "-$5" -extfile "$1.ext"
  der "$1"
}

mkoldroot sha1root sha1
mkoldroot md5root  md5
# An attacker's own self-signed certificate, with sha1root's name and a key of
# its own. The parse used to refuse it, but only because of the hash. It parses
# now, and S5 checks what stops it: the signature check under the stored key
# (x509_anchored). A matching subject on its own is worth nothing.
printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=fakeroot\n[v3]\n%s\n' "$CA" > fakeroot.cnf
ssl "mint a forged copy of sha1root" req -x509 -newkey rsa:2048 -nodes -keyout fakeroot.key \
  -out fakeroot.crt -days 2 -subj "/O=word profile/CN=sha1root" -sha1 -extensions v3 -config fakeroot.cnf
der fakeroot
mkcert    undersha1 "/CN=$HOST" "$LEAF" sha1root
mkcert    undermd5  "/CN=$HOST" "$LEAF" md5root
mkcert    sha1inter "/O=word profile/CN=sha1inter" "$CA" sha1root
mkcert    viasha1   "/CN=$HOST" "$LEAF" sha1inter
mkoldcert sha1leaf  "/CN=$HOST" "$LEAF" rootca sha1
mkoldcert sha1int   "/O=word profile/CN=sha1int" "$CA" rootca sha1
mkcert    undersha1int "/CN=$HOST" "$LEAF" sha1int
mkcert    forgedleaf   "/CN=$HOST" "$LEAF" fakeroot
# Every PSS parameter left at its default, so openssl writes them as an empty
# SEQUENCE: the hash is SHA-1, the mask MGF1 with SHA-1 and the salt 20 bytes.
printf '[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN=pssroot\n[v3]\n%s\n' "$CA" > pssroot.cnf
ssl "mint the RSA-PSS root pssroot" req -x509 -newkey rsa:2048 -nodes -keyout pssroot.key \
  -out pssroot.crt -days 2 -subj "/O=word profile/CN=pssroot" -sha1 \
  -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:20 -extensions v3 -config pssroot.cnf
der pssroot
mkcert    underpss     "/CN=$HOST" "$LEAF" pssroot

# --- O: the order the peer sends the chain in --------------------------------
# RFC 8446 4.4.2 fixes the position of one certificate: the end-entity
# certificate must come first. Extra certificates should be tolerated, since
# servers send a current and a retired intermediate during a transition, and
# others are just misconfigured.
#
# Six of the thousand most popular domains send a chain a strict walk refuses:
# telekom.net and ultradns.com send their leaf twice, and warnerbros.com,
# digikala.com, uidai.gov.in and terra.com.br send a root (a cross-signed one,
# in terra's case) before the intermediate that needs it. Browsers fetch all
# six, and word refused all six until it searched for the path instead of
# assuming it. `unrelated` is a certificate from an unrelated hierarchy, so
# the search also has to step over one that has nothing to do with the chain.
mkcert unrelated "/O=word profile/CN=unrelated" "$CA
extendedKeyUsage=serverAuth,clientAuth" untrusted

# --- P: a pathLenConstraint too big for a 63-bit integer ----------------------
# pathLen is an INTEGER with no upper bound. An 8-byte one used to overflow the
# arithmetic in x509_bc, so any server could stop a word client with an
# "integer overflow" fault by sending one certificate. It's a legal (if silly)
# value, and all three verifiers accept it.
mkcert bigpl      "/O=word profile/CN=bigpl" "basicConstraints=critical,CA:TRUE,pathlen:4611686018427387904
keyUsage=critical,keyCertSign" rootca
mkcert underbigpl "/CN=$HOST" "$LEAF" bigpl

# --- T: the validity window (rule 2) -----------------------------------------
# Every fixture above is valid for two days from now. These are not: dates fixed
# in the past or far in the future, so the verdict never depends on the clock
# the run happens to have. `openssl ca` takes the dates on every OpenSSL 3, where
# `x509 -not_before` is newer than some runners' copies.
mkdated() { # mkdated <name> <subject> <ext-lines> <issuer-name|self> <start> <end>
  printf '%s\n' "$3" > "$1.ext"
  newkey "$1.key"
  ssl "request $1" req -new -key "$1.key" -out "$1.csr" -subj "$2"
  mkdir -p "$1.db" && : > "$1.db/index" && echo 01 > "$1.db/serial"
  printf '[ca]\ndefault_ca=c\n[c]\ndatabase=%s.db/index\nserial=%s.db/serial\nnew_certs_dir=%s.db\ndefault_md=sha256\npolicy=p\nunique_subject=no\n[p]\norganizationName=optional\ncommonName=supplied\n' \
    "$1" "$1" "$1" > "$1.ca.cnf"
  if [ "$4" = self ]; then
    ssl "self-sign $1 between $5 and $6" ca -batch -notext -selfsign -config "$1.ca.cnf" -keyfile "$1.key" \
      -in "$1.csr" -out "$1.crt" -startdate "$5" -enddate "$6" -extfile "$1.ext"
  else
    ssl "sign $1 with $4 between $5 and $6" ca -batch -notext -config "$1.ca.cnf" -cert "$4.crt" -keyfile "$4.key" \
      -in "$1.csr" -out "$1.crt" -startdate "$5" -enddate "$6" -extfile "$1.ext"
  fi
  der "$1"
}
PAST1=20200101000000Z; PAST2=20200102000000Z; FUT1=20990101000000Z; FUT2=20991231000000Z
mkdated expiredleaf "/CN=$HOST" "$LEAF" rootca "$PAST1" "$PAST2"
mkdated futureleaf  "/CN=$HOST" "$LEAF" rootca "$FUT1" "$FUT2"
mkdated expiredint  "/O=word profile/CN=expiredint" "$CA" rootca "$PAST1" "$PAST2"
mkcert  underexpiredint "/CN=$HOST" "$LEAF" expiredint
mkdated expiredroot "/O=word profile/CN=expiredroot" "$CA" self "$PAST1" "$PAST2"
mkcert  underexpiredroot "/CN=$HOST" "$LEAF" expiredroot
# A notBefore before 1970 is a negative number of seconds. word used to answer
# -1 for a time it couldn't read and took any negative time for that, so this
# leaf didn't parse. Its start is the last second of 1969, which is -1 itself.
mkdated pre1970leaf "/CN=$HOST" "$LEAF" rootca 19691231235959Z "$FUT2"

# --- L: pathLenConstraint (rule 4) -------------------------------------------
# A CA with pathlen:0 may issue leaves and nothing else. Once it is the anchor
# with an intermediate under it, and once it is an intermediate with another
# under it.
mkroot pl0root "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign"
mkcert pl0rootint  "/O=word profile/CN=pl0rootint" "$CA" pl0root
mkcert underpl0root "/CN=$HOST" "$LEAF" pl0rootint
mkcert pl0int      "/O=word profile/CN=pl0int" "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign" rootca
mkcert pl0sub      "/O=word profile/CN=pl0sub" "$CA" pl0int
mkcert underpl0sub "/CN=$HOST" "$LEAF" pl0sub
mkcert viapl0int   "/CN=$HOST" "$LEAF" pl0int

# --- I: a literal address (rule 1's other half) --------------------------------
# A host that is an IPv4 address is matched against iPAddress SANs and never
# against a dNSName, so a certificate for the name 127.0.0.1 doesn't answer
# for the address.
IPHOST=127.0.0.1
mkcert ipleaf    "/CN=ip" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.1" rootca
mkcert ipother   "/CN=ip" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:127.0.0.2" rootca
mkcert ipasname  "/CN=ip" "basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:127.0.0.1" rootca

# ---- the comparison ----------------------------------------------------------
# check <label> <want-word> <want-openssl> <want-go> <anchor> <leaf> [inters...]
# The host is $HOST, or $CHECK_HOST when a case sets it; openssl is asked to
# match an address with -verify_ip and a name with -verify_hostname.
check() {
  label=$1; ww=$2; wo=$3; wg=$4; anchor=$5; leaf=$6
  shift 6
  ders=""; untrusted=""
  for i in "$@"; do
    ders="$ders $i.der"
    untrusted="$untrusted -untrusted $i.crt"
  done
  host=${CHECK_HOST:-$HOST}
  case "$host" in
    *[!0-9.]*) match="-verify_hostname" ;;
    *)         match="-verify_ip" ;;
  esac

  gotw=$("$tmp/wverdict" "$host" "$anchor.der" "$leaf.der" $ders 2>/dev/null | head -1)

  if openssl verify -purpose sslserver $match "$host" \
       -CAfile "$anchor.crt" $untrusted "$leaf.crt" >/dev/null 2>&1
  then goto=ACCEPTED
  else goto=REJECTED
  fi

  # With no Go on the box the expectation stands in for the answer, so the case
  # still checks word against openssl and reports which oracles ran.
  gotg=$wg
  [ -n "$GOVERDICT" ] && gotg=$("$GOVERDICT" "$host" "$anchor.der" "$leaf.der" $ders 2>/dev/null | head -1)

  if [ "$gotw" = "$ww" ] && [ "$goto" = "$wo" ] && [ "$gotg" = "$wg" ]; then
    ok "$label"
  else
    bad "$label" "word $gotw (want $ww) | openssl $goto (want $wo) | go $gotg (want $wg)"
  fi
}

echo "== well-formed chains: all three ACCEPT (a verifier that refuses everything fails here) =="
check "A1 leaf with serverAuth, issued by the anchor"       ACCEPTED ACCEPTED ACCEPTED rootca  good
check "A2 the same, RSA-2048 throughout"                    ACCEPTED ACCEPTED ACCEPTED rootrsa goodrsa
check "A3 leaf via an intermediate that permits serverAuth" ACCEPTED ACCEPTED ACCEPTED rootca  viainter inter
check "A4 leaf via an intermediate carrying no EKU"         ACCEPTED ACCEPTED ACCEPTED rootca  vianoeku internoeku
check "A5 leaf carrying no EKU (unrestricted)"              ACCEPTED ACCEPTED ACCEPTED rootca  noeku
check "A6 wildcard SAN covering the host"                   ACCEPTED ACCEPTED ACCEPTED rootca  wildcard
check "A7 unknown extension, NOT critical, is ignored"      ACCEPTED ACCEPTED ACCEPTED rootca  unkncrit
check "A8 the server also sends the anchor"                 ACCEPTED ACCEPTED ACCEPTED rootca  good rootca

echo
echo "== critical extensions nothing here processes: RFC 5280 4.2 says REJECT =="
check "C1 critical unknown extension in the leaf"           REJECTED REJECTED REJECTED rootca critleaf
check "C2 critical unknown extension in the intermediate"   REJECTED REJECTED REJECTED rootca undercritint critint

echo
echo "== extendedKeyUsage: the purpose the issuer wrote down =="
check "E1 leaf marked critical clientAuth, not serverAuth"  REJECTED REJECTED REJECTED rootca ekucli
check "E2 the same, not marked critical"                    REJECTED REJECTED REJECTED rootca ekuclinc
check "E3 leaf marked for OCSP signing"                     REJECTED REJECTED REJECTED rootca ekuocsp
check "E4 intermediate marked clientAuth, serverAuth leaf"  REJECTED REJECTED REJECTED rootca underekucli interekucli

echo
echo "== path validation the profile shares with every other verifier =="
check "V1 non-CA certificate used as an intermediate"       REJECTED REJECTED REJECTED rootca undernotca notca
check "V2 intermediate whose keyUsage omits keyCertSign"    REJECTED REJECTED REJECTED rootca undernosign nosign
check "V3 SAN does not cover the host"                      REJECTED REJECTED REJECTED rootca wronghost
check "V4 chain to an anchor that is not the trust store"   REJECTED REJECTED REJECTED rootca untrustedleaf
check "V5 name constraint the leaf VIOLATES"                REJECTED REJECTED REJECTED rootca underncbad ncintx
check "V6 the same constraint, not marked critical"         REJECTED REJECTED REJECTED rootca underncbadnc ncintxnc

echo
echo "== keyUsage: what the key may be used for =="
check "K1 leaf keyUsage allows digitalSignature and keyEncipherment" ACCEPTED ACCEPTED ACCEPTED rootrsa kusigenc
check "K2 leaf carrying no keyUsage (unrestricted)"          ACCEPTED ACCEPTED ACCEPTED rootca  kunone

echo
echo "== signatures older than SHA-256: refused on the path, ignored on the anchor =="
check "S1 SHA-1 self-signed anchor, SHA-256 leaf under it" ACCEPTED ACCEPTED ACCEPTED sha1root undersha1
check "S2 the same with an MD5 self-signed anchor"         ACCEPTED ACCEPTED ACCEPTED md5root  undermd5
check "S3 leaf via an intermediate under the SHA-1 anchor" ACCEPTED ACCEPTED ACCEPTED sha1root viasha1 sha1inter
check "S4 the server also sends the SHA-1 anchor"          ACCEPTED ACCEPTED ACCEPTED sha1root undersha1 sha1root
check "S5 a forged self-signed copy of the SHA-1 anchor"   REJECTED REJECTED REJECTED sha1root forgedleaf fakeroot
# The case only tests the default if openssl wrote the parameters empty: the
# AlgorithmIdentifier is the rsassaPss OID and then 30 00.
s6="S6 an RSA-PSS anchor on its SHA-1 default, SHA-256 leaf"
if od -An -tx1 -v pssroot.der | tr -d ' \n' | grep -q '300d06092a864886f70d01010a3000'; then
  check "$s6" ACCEPTED ACCEPTED ACCEPTED pssroot underpss
else
  bad "$s6" "openssl did not write the root's PSS parameters as an empty SEQUENCE"
fi

echo
echo "== the chain as the peer actually sends it (RFC 8446 4.4.2) =="
check "O1 the leaf sent twice, then the intermediate"    ACCEPTED ACCEPTED ACCEPTED rootca viainter viainter inter
check "O2 the anchor before the intermediate under it"   ACCEPTED ACCEPTED ACCEPTED rootca viainter rootca inter
check "O3 an unrelated certificate in the middle"        ACCEPTED ACCEPTED ACCEPTED rootca viainter unrelated inter
check "O4 two intermediates, the needed one last"        ACCEPTED ACCEPTED ACCEPTED rootca viainter internoeku inter
check "O5 junk before the issuer, all of it ignored"     ACCEPTED ACCEPTED ACCEPTED rootca viainter rootca crossroot inter

echo
echo "== a chain that runs past the anchor: the shape the web actually sends =="
check "X1 surplus cross-signed root after the anchor"  ACCEPTED ACCEPTED ACCEPTED rootca viainter inter crossroot
check "X2 the same, leaf issued by the anchor itself"  ACCEPTED ACCEPTED ACCEPTED rootca good crossroot
check "X3 the surplus cert alone cannot bridge to it"  REJECTED REJECTED REJECTED rootca untrustedleaf crossroot

echo "== a pathLenConstraint past 2^62 =="
check "P1 intermediate with pathlen 2^62, leaf under it" ACCEPTED ACCEPTED ACCEPTED rootca underbigpl bigpl

echo
echo "== the validity window: nothing expired, nothing not yet valid (rule 2) =="
check "T1 the leaf expired in 2020"                         REJECTED REJECTED REJECTED rootca expiredleaf
check "T2 the leaf is not valid until 2099"                 REJECTED REJECTED REJECTED rootca futureleaf
check "T3 the intermediate expired, the leaf is in date"    REJECTED REJECTED REJECTED rootca underexpiredint expiredint
check "T4 the anchor itself expired"                        REJECTED REJECTED REJECTED expiredroot underexpiredroot
check "T5 the leaf is valid from 1969-12-31T23:59:59Z to 2099" ACCEPTED ACCEPTED ACCEPTED rootca pre1970leaf

echo
echo "== pathLenConstraint leaves room for what is beneath (rule 4) =="
check "L1 a pathlen:0 intermediate issuing the leaf"        ACCEPTED ACCEPTED ACCEPTED rootca viapl0int pl0int
check "L2 a pathlen:0 intermediate issuing another CA"      REJECTED REJECTED REJECTED rootca underpl0sub pl0sub pl0int
check "L3 a pathlen:0 anchor with an intermediate under it" REJECTED REJECTED REJECTED pl0root underpl0root pl0rootint

echo
echo "== a literal address is matched against iPAddress SANs (rule 1) =="
CHECK_HOST=$IPHOST
check "I1 an iPAddress SAN for the address"                 ACCEPTED ACCEPTED ACCEPTED rootca ipleaf
check "I2 an iPAddress SAN for another address"             REJECTED REJECTED REJECTED rootca ipother
check "I3 the address written as a dNSName"                 REJECTED REJECTED REJECTED rootca ipasname
CHECK_HOST=

echo
echo "== documented divergences (SPEC 12.2) =="
check "D1 anyExtendedKeyUsage in place of serverAuth"       REJECTED REJECTED ACCEPTED rootca ekuany
check "D2 name constraint the leaf SATISFIES"               REJECTED ACCEPTED ACCEPTED rootca underncok ncint
# D3 and D4: what counts as a trust anchor. word and Go say whatever is in the
# store; openssl also wants it self-signed, unless it's given -partial_chain.
# That's openssl's default, not a rule from RFC 5280, which leaves the choice of
# anchors to the relying party.
#
# word follows Go because the other rule turned out to be inconsistent: word
# used to reject [leaf, inter] against a store holding `inter` while accepting
# [leaf] alone against the same store, so the answer depended on whether the
# server sent a spare copy of the anchor. "What's in your store is trusted" is
# the rule a reader can predict.
check "D3 an intermediate placed in the store is an anchor" ACCEPTED REJECTED ACCEPTED inter viainter
check "D4 the same, with that anchor sent again beneath it" ACCEPTED REJECTED ACCEPTED inter viainter inter

# D5: a leaf restricted to keyEncipherment. TLS 1.3 authenticates the server by
# a signature made with the leaf's key, and RFC 8446 4.4.2.2 requires
# digitalSignature wherever keyUsage is present. openssl's sslserver purpose also
# covers TLS 1.2 RSA key exchange, which needed only keyEncipherment; Go ignores
# a leaf's keyUsage. word is a TLS 1.3 client and refuses it.
check "D5 leaf keyUsage without digitalSignature"          REJECTED ACCEPTED ACCEPTED rootrsa kuenc
# D6/D7: a keyUsage with no bits in it. RFC 5280 4.2.1.3 requires at least one,
# and openssl refuses the certificate; Go reads it as an absent keyUsage and so
# as unrestricted, which on an intermediate means the keyCertSign rule never
# applies. word used to read it that way too.
check "D6 intermediate keyUsage holding no bits at all"    REJECTED REJECTED ACCEPTED rootca underkuempty kuemptyint
check "D7 leaf keyUsage holding no bits at all"            REJECTED REJECTED ACCEPTED rootca kuemptyleaf
# D8 and D9: a signature on the path made with SHA-1. word refuses it: there's
# no SHA-1 in this implementation, so the link can't be checked. Go refuses it
# too (crypto/x509 dropped SHA-1 verification in 1.18). openssl still verifies
# it at its default security level, which is what -auth_level and @SECLEVEL
# exist to change. The anchor's own self-signature is a different question,
# covered by S1 to S5 above, where all three agree.
check "D8 leaf signed with SHA-1"                          REJECTED ACCEPTED REJECTED rootca sha1leaf
check "D9 intermediate signed with SHA-1"                  REJECTED ACCEPTED REJECTED rootca undersha1int sha1int
# D10 and D11: the constraints word doesn't implement, not marked critical. word
# refuses any certificate carrying one (see N above). openssl and Go implement
# name constraints, so they accept a leaf that satisfies one. For D11 Go does
# policy validation and refuses too (requireExplicitPolicy:0 and a leaf with no
# policy), while openssl only checks policies when you ask it to.
check "D10 non-critical name constraint the leaf SATISFIES" REJECTED ACCEPTED ACCEPTED rootca underncnc ncintnc
check "D11 non-critical policyConstraints on the path"      REJECTED ACCEPTED REJECTED rootca underpc pcint

echo
echo "== the host's own trust store: every anchor it offers has to parse =="
# The fixtures above ask what the verifier does with a chain. This asks what's
# left of the host's own trust store once it's parsed: the PEM bundle on Linux
# and macOS, the Crypt32 ROOT store on Windows. net_load_roots keeps the anchors
# that parse and says nothing about the rest, so an anchor lost at the parse
# makes a fetch fail for a reason no message mentions. That's how 19 of 53
# Windows anchors went missing.
#
# The places to look are net_ca_paths's own list, read from the compiler's
# source so this file doesn't keep a second copy.
capaths=$(sed -n '/^net_ca_paths()/,/^$/p' "$root/compiler/word.w" \
          | sed -n 's/^ *p\[[0-9]*\] = "\(.*\)"$/\1/p')
[ -n "$capaths" ] || { echo "  FAIL: net_ca_paths is not where this expects it in compiler/word.w"; fail=$((fail+1)); }
store=$("$tmp/wverdict" --store $capaths 2>/dev/null | head -1)
offered=$(printf '%s' "$store" | cut -d' ' -f2)
parsed=$(printf '%s' "$store" | cut -d' ' -f3)
# Anchors whose key is ML-DSA or SLH-DSA (see x509_verdict.w). word verifies
# neither, so they're counted apart instead of as lost.
pq=$(printf '%s' "$store" | cut -d' ' -f4)
# f5-, not f5: "the OS trust store" is four words, and cutting the source to
# its first word would print "all 53 anchors in the parse".
source=$(printf '%s' "$store" | cut -d' ' -f5-)
if [ "${store%% *}" = STORE ] && [ "${offered:-0}" -gt 0 ] 2>/dev/null; then
  if [ "$offered" = "$parsed" ]; then
    ok "all $offered anchors in $source parse"
  elif [ "$offered" = $((parsed + pq)) ]; then
    ok "all $parsed anchors in $source parse, apart from $pq ML-DSA or SLH-DSA ones, which word doesn't verify"
  else
    bad "the trust store lost anchors" \
        "$parsed of $offered parse in $source; $((offered - parsed - pq)) anchors a fetch cannot use"
  fi
else
  # A host with no anchors at all isn't this verifier's problem: a container
  # with no ca-certificates package has none.
  echo "  SKIP: this host offers no trust anchors [$store]"
fi

echo
if [ "$skipped_go" = 1 ]; then
  echo "test_x509_profile: $pass passed, $fail failed (word vs openssl; the go oracle was skipped)"
else
  echo "test_x509_profile: $pass passed, $fail failed (word vs openssl vs go)"
fi
[ "$fail" -eq 0 ]
