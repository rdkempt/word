#!/bin/sh
# test_fuzz_tls.sh: fuzzing the TLS handshake decoders.
#
# test_fuzz.sh covers the X.509 decoder. This covers the decoders that run
# before it, on bytes a server sends before anything is authenticated: the
# handshake framing, tls13_parse_server_hello, tls13_is_hrr, tls13_parse_hrr,
# tls13_parse_cert_request, tls13_parse_certificate, and the flight they arrive
# in.
#
# A failure is the same as in test_fuzz.sh: a hang, a signal, or exit 70
# (word's bounds check firing, which means a decoder indexed a region with a
# length the server chose). That file says why a safe fault is still a bug.
#
# An earlier certificate parser capped neither the certificate count nor the
# walk, so a 208-byte Certificate declaring 40 empty entries wrote past the
# arrays behind it. The "many-certs" seed is that message.
#
# openssl mints the seed certificates, for development and CI as elsewhere;
# word never needs it to build or run.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
# Git Bash's own path rewriting is turned off, because it takes a subject for a
# path: `-subj /CN=fuzz-tls` reached openssl.exe as
# `C:/Program Files/Git/CN=fuzz-tls`. Every path this script hands a native
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

{ printf 'import sys\nimport fs\n'
  python3 "$root/dev/toolchain/netlib_cat.py" sha256 sha512 hmac bignum rsa ecdsa ecdh der x509 chacha20 poly1305 aes gcm x25519 tls
  cat "$here/fuzz/fuzz_handshake.w"
} > "$tmp/app.w"
if ! "$WORD" build "$tmp/app.w" -o "$tmp/fuzz" >"$tmp/buildlog" 2>&1; then
  echo "FAIL: could not build the handshake fuzz harness:"; sed 's/^/  /' "$tmp/buildlog"; exit 1
fi

mint req -new -x509 -newkey rsa:2048 -nodes -keyout "$tmp/k" -sha256 -days 30 \
  -subj "/CN=fuzz-tls" -outform DER -out "$tmp/a.der"
mint ecparam -name prime256v1 -genkey -noout -out "$tmp/ke"
mint req -new -x509 -key "$tmp/ke" -sha256 -days 30 \
  -subj "/CN=fuzz-tls-ec" -outform DER -out "$tmp/b.der"

python3 - "$tmp" <<'PY'
import sys, os
d = sys.argv[1]
a = open(os.path.join(d, "a.der"), "rb").read()
b = open(os.path.join(d, "b.der"), "rb").read()
def u24(n): return n.to_bytes(3, "big")
def u16(n): return n.to_bytes(2, "big")
def hs(t, body): return bytes([t]) + u24(len(body)) + body
def certmsg(certs):
    lst = b"".join(u24(len(c)) + c + u16(0) for c in certs)
    return hs(0x0b, b"\x00" + u24(len(lst)) + lst)
def sh(exts=b"", rnd=None):
    body = b"\x03\x03" + (rnd or bytes(range(32))) + b"\x20" + bytes(32) \
         + b"\x13\x01" + b"\x00" + u16(len(exts)) + exts
    return hs(0x02, body)
HRR = bytes.fromhex("CF21AD74E59A6111BE1D8C021E65B891C2A211167ABB8C5E079E09E2C8A8339C")
ks = lambda g, k: bytes([0x00,0x33]) + u16(4+len(k)) + u16(g) + u16(len(k)) + k
def certreq(ctx=b""):
    # RFC 8446 4.3.2: the context, then extensions, including
    # signature_algorithms, which a request has to carry.
    sa = u16(4) + u16(0x0403) + u16(0x0804)
    exts = u16(0x000d) + u16(len(sa)) + sa
    return hs(0x0d, bytes([len(ctx)]) + ctx + u16(len(exts)) + exts)
# A whole second flight with the request in it: EncryptedExtensions, the
# request, a Certificate, a CertificateVerify and a Finished, back to back.
flight_cr = hs(0x08, u16(0)) + certreq() + certmsg([a]) \
          + hs(0x0f, u16(0x0403) + u16(2) + b"\x30\x00") + hs(0x14, bytes(32))
seeds = {
  "cert-1":      certmsg([a]),
  "cert-2":      certmsg([a, b]),
  "many-certs":  certmsg([b""] * 40),
  "sh-x25519":   sh(ks(0x001d, bytes(32))),
  "sh-mlkem":    sh(ks(0x11ec, bytes(1120))),
  "sh-bigks":    sh(bytes([0x00,0x33]) + u16(6) + u16(0x11ec) + u16(0xffff)),
  # a ServerHello whose length runs past what arrived, which used to stop the
  # driver with a fault before anything parsed it
  "sh-shortlen": b"\x02\xff\xff\xff\x03\x03\x00\x00",
  "hrr":         sh(ks(0x0017, b""), rnd=HRR),
  "certreq":     certreq(),
  "certreq-ctx": certreq(bytes(range(1, 9))),
  "flight-cr":   flight_cr,
}
for name, blob in seeds.items():
    open(os.path.join(d, "seed." + name), "wb").write(blob)
print("\n".join("%s %d" % (n, len(v)) for n, v in seeds.items()))
PY

# Offsets per seed. These decoders do no public-key arithmetic, so they're cheap
# enough to cover more offsets. Raise it for a soak.
OFFSETS=${FUZZ_OFFSETS:-400}

runs=0; faults=0; hangs=0; crashes=0
run_one() {
  runs=$((runs + 1)); rc=0
  timeout 10 "$tmp/fuzz" "$1" >/dev/null 2>"$tmp/rc.err" || rc=$?
  if [ "$rc" = 124 ]; then echo "  HANG:  $2"; hangs=$((hangs + 1))
  elif [ "$rc" = 70 ]; then echo "  FAULT: $2 -- $(head -1 "$tmp/rc.err")"; faults=$((faults + 1))
  elif [ "$rc" -ge 128 ]; then echo "  CRASH: $2 (signal $((rc - 128)))"; crashes=$((crashes + 1))
  # Any other status means the driver didn't return either. On Windows that's
  # how most crashes arrive (see run_one in test_fuzz.sh).
  elif [ "$rc" != 0 ]; then echo "  CRASH: $2 (exit $rc)"; crashes=$((crashes + 1)); fi
}

for seed in "$tmp"/seed.*; do
  name=${seed##*seed.}
  n=$(wc -c < "$seed")
  echo "seed $name ($n bytes):"
  run_one "$seed" "$name baseline"
  python3 - "$seed" "$tmp/m" "$OFFSETS" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
base, want = sys.argv[2], int(sys.argv[3])
step = max(1, len(data) // want)
for k in list(range(0, len(data), step)) + [len(data)]:
    open("%s.trunc.%d" % (base, k), "wb").write(data[:k])
for off in range(0, len(data), step):
    for val in (0xFF, 0x84, 0x00):
        m = bytearray(data); m[off] = val
        open("%s.b%d.%d" % (base, val, off), "wb").write(bytes(m))
PY
  for f in "$tmp"/m.*; do run_one "$f" "$name ${f##*/m.}"; done
  rm -f "$tmp"/m.*
done

echo
echo "test_fuzz_tls: $runs inputs, $faults bounds faults, $hangs hangs, $crashes crashes"
[ "$faults" -eq 0 ] && [ "$hangs" -eq 0 ] && [ "$crashes" -eq 0 ]
