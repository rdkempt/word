#!/bin/sh
# test_fuzz.sh: fuzzing the X.509 / DER decoder.
#
# The decoder (der.w and x509.w) runs on a certificate the server sent, before
# anything about it is authenticated, so a length it trusts too early is a
# remote bug (docs/SECURITY.md section 5). This feeds malformed certificates to
# the entry points the TLS handshake uses and checks that each one is rejected
# (the call returns) instead of faulting or looping. Two kinds of mutation,
# applied to real seed certificates:
#   - truncation: every prefix of the certificate (does the parser read past
#     the end?)
#   - byte corruption: each offset forced to 0xFF and to 0x84 (does a corrupted
#     length send der_read out of bounds, or a copy loop past a region?)
#
# Why a bounds fault counts as a failure: every region access in word is
# bounds-checked, so a decoder that walks off the end of a certificate stops
# with `index N out of bounds` and exit 70 instead of reading whatever is next
# in memory. That's safe, but it's still a decoder trusting a number it read
# off the wire, so exit 70 fails this test. So does a hang (a parse loop whose
# bound the input controls), and so does any signal.
#
# openssl is only used to mint seed certificates, for development and CI, the
# way GNU as is used in test_encoder_vs_as.sh. word never needs it. Without it
# the test skips.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
# Git Bash's own path rewriting is turned off, because it takes a subject for a
# path: `-subj /CN=fuzz-rsa2048` reached openssl.exe as
# `C:/Program Files/Git/CN=fuzz-rsa2048`. Every path this script hands a native
# program is converted explicitly instead, as in test_x509_profile.sh. These do
# nothing on Linux and macOS.
MSYS_NO_PATHCONV=1; MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
WORD=$(wordbin "${WORD:-$root/word}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
if ! command -v openssl >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: openssl/python3 not on PATH (fuzz seed minting is dev/CI-only)"; exit 0
fi

tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT

# Every seed is minted through this, which keeps openssl's output and prints it
# with the command if it fails. Under `set -e`, throwing the output away left an
# empty log.
mint() { # mint <openssl args...>
  if ! openssl "$@" >"$tmp/ssl.log" 2>&1; then
    echo "FAIL: openssl could not mint a seed"; echo "  openssl $*"
    sed 's/^/  | /' "$tmp/ssl.log"; exit 1
  fi
}

# Build the harness once. The driver is concatenated after the modules it calls,
# the same way dev/toolchain/test_crypto_w.sh builds a KAT: a folder is a program
# (SPEC 11), so a second .w beside the driver would be folded in as well.
{ printf 'import sys\nimport fs\n'
  python3 "$root/dev/toolchain/netlib_cat.py" sha256 sha512 bignum rsa ecdsa der x509
  cat "$here/fuzz/fuzz_x509.w"
} > "$tmp/app.w"
if ! "$WORD" build "$tmp/app.w" -o "$tmp/fuzz" >"$tmp/buildlog" 2>&1; then
  echo "FAIL: could not build the X.509 fuzz harness:"; sed 's/^/  /' "$tmp/buildlog"; exit 1
fi

# seed certs across the signature/key types the decoder dispatches on
mint req -new -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k1" -sha256 -days 30 \
  -subj "/CN=fuzz-rsa2048" -outform DER -out "$tmp/rsa.der"
mint req -new -x509 -newkey rsa:4096 -nodes -keyout "$tmp/k2" -sha256 -days 30 \
  -subj "/CN=fuzz-rsa4096" -outform DER -out "$tmp/rsa4096.der"
mint ecparam -name prime256v1 -genkey -noout -out "$tmp/ke"
mint req -new -x509 -key "$tmp/ke" -sha256 -days 30 \
  -subj "/CN=fuzz-p256" -outform DER -out "$tmp/p256.der"
mint ecparam -name secp384r1 -genkey -noout -out "$tmp/ke4"
mint req -new -x509 -key "$tmp/ke4" -sha384 -days 30 \
  -subj "/CN=fuzz-p384" -outform DER -out "$tmp/p384.der"
mint genpkey -algorithm ed25519 -out "$tmp/ked"
mint req -new -x509 -key "$tmp/ked" -days 30 \
  -subj "/CN=fuzz-ed25519" -outform DER -out "$tmp/ed.der"

# How many offsets to hit per seed. One verification is milliseconds of bignum
# arithmetic, so every byte of a 1.7 KB RSA-4096 certificate would take
# minutes. The offsets are spread evenly instead. Raise it
# (FUZZ_OFFSETS=100000 sh dev/toolchain/test_fuzz.sh) for a long soak.
OFFSETS=${FUZZ_OFFSETS:-220}

runs=0; faults=0; hangs=0; crashes=0

run_one() { # <file> <label>
  runs=$((runs + 1))
  rc=0
  timeout 10 "$tmp/fuzz" "$1" >/dev/null 2>"$tmp/rc.err" || rc=$?
  if [ "$rc" = 124 ]; then
    echo "  HANG:  $2"; hangs=$((hangs + 1))
  elif [ "$rc" = 70 ]; then
    echo "  FAULT: $2 -- $(head -1 "$tmp/rc.err")"; faults=$((faults + 1))
  elif [ "$rc" -ge 128 ]; then
    echo "  CRASH: $2 (signal $((rc - 128)))"; crashes=$((crashes + 1))
  elif [ "$rc" != 0 ]; then
    # The driver exits 0 whatever the answer, so any other status means it
    # didn't return either. On Windows that's how most crashes arrive: Git Bash
    # reports an access violation as a signal, but a stack overflow, a divide
    # trap or a fail-fast as plain 127.
    echo "  CRASH: $2 (exit $rc)"; crashes=$((crashes + 1))
  fi
}

fuzz_seed() { # <der-file> <name>
  seed="$1"; name="$2"
  [ -s "$seed" ] || { echo "  skip: $name (no seed cert)"; return; }
  n=$(wc -c < "$seed")
  echo "seed $name ($n bytes):"
  run_one "$seed" "$name baseline"          # the untouched cert, handled cleanly
  python3 - "$seed" "$tmp/m" "$OFFSETS" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
base, want = sys.argv[2], int(sys.argv[3])
step = max(1, len(data) // want)
for k in list(range(0, len(data), step)) + [len(data)]:
    open("%s.trunc.%d" % (base, k), "wb").write(data[:k])
# 0xFF is a long-form length claiming 127 length bytes; 0x84 is a long form with
# four, so the length that follows is a 32-bit number the input chooses.
for off in range(0, len(data), step):
    for val in (0xFF, 0x84):
        b = bytearray(data); b[off] = val
        open("%s.b%d.%d" % (base, val, off), "wb").write(bytes(b))
PY
  for f in "$tmp"/m.trunc.*; do run_one "$f" "$name trunc@${f##*.}"; done
  for f in "$tmp"/m.b255.*;  do run_one "$f" "$name 0xFF@${f##*.}"; done
  for f in "$tmp"/m.b132.*;  do run_one "$f" "$name 0x84@${f##*.}"; done
  rm -f "$tmp"/m.*
}

fuzz_seed "$tmp/rsa.der"     "rsa2048"
fuzz_seed "$tmp/rsa4096.der" "rsa4096"
fuzz_seed "$tmp/p256.der"    "p256"
fuzz_seed "$tmp/p384.der"    "p384"
fuzz_seed "$tmp/ed.der"      "ed25519"

echo "test_fuzz: $runs inputs, $faults bounds faults, $hangs hangs, $crashes crashes"
[ "$faults" = 0 ] && [ "$hangs" = 0 ] && [ "$crashes" = 0 ]
