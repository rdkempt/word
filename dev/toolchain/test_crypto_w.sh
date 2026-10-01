#!/bin/sh
# test_crypto_w.sh: known-answer tests for the crypto in the `net` library.
# The library is word source carried in compiler/word.w (netlib_cat.py pulls it
# out here) and compiled into a program like any other code, so it's the same
# implementation on every target.
#
# Each test concatenates the modules it needs with its driver into one app.w,
# the same thing with_netlib does for a net program, done by hand so a module
# can be tested on its own. It's built in a temp directory because a folder is
# a program (SPEC 11): a driver sitting beside the others would be folded into
# every one of them. Every vector is checked against a published one, and the
# drivers say where each comes from.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0; CAP=

# run_kat <driver> <module...>
run_kat() {
  driver="$1"; shift
  # `import sys` has to be the first line of a program, and several modules
  # (bignum, ecdsa and the hashes among them) use mark/reset so a verification
  # doesn't leave its temporaries in the arena. An unused import isn't an error,
  # so every driver gets it.
  echo "import sys" > "$tmp/app.w"
  python3 "$root/dev/toolchain/netlib_cat.py" "$@" >> "$tmp/app.w"
  cat "$here/crypto_w/$driver.w" >> "$tmp/app.w"
  if ! "$WORD" build "$tmp/app.w" -o "$tmp/kat" >"$tmp/err" 2>&1; then
    echo "  FAIL: $driver did not build"; sed 's/^/    /' "$tmp/err"; fail=$((fail+1)); return
  fi
  # CAP (KiB) caps the native run's address space where `ulimit -v` works
  # (Linux). Elsewhere the KAT runs uncapped and only the answer is checked.
  rc=0
  if [ -n "$CAP" ] && ( ulimit -v "$CAP" ) 2>/dev/null; then
    ( ulimit -v "$CAP"; exec "$tmp/kat" ) || rc=$?
  else
    "$tmp/kat" || rc=$?
  fi
  [ "$rc" = 0 ] || fail=$((fail+1))
  # The same program on arm64. Writing the library in word means one
  # implementation for every target.
  if [ -n "$QEMU" ]; then
    "$WORD" build -arm64 "$tmp/app.w" -o "$tmp/kat.a64" >"$tmp/err" 2>&1 || {
      echo "  FAIL: $driver did not build for arm64"; sed 's/^/    /' "$tmp/err"; fail=$((fail+1)); return; }
    rc=0; $QEMU "$tmp/kat.a64" > "$tmp/a64.txt" 2>&1 || rc=$?
    if [ "$rc" = 0 ]; then sed 's/^/  arm64: /' "$tmp/a64.txt"
    else echo "  FAIL: $driver on arm64:"; sed 's/^/    /' "$tmp/a64.txt"; fail=$((fail+1)); fi
  fi
}

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
# On an arm64 Linux host the arm64 build runs natively. That build is a Linux
# ELF, and on a Mac the host build above is already the arm64 run.
case "$(uname -s)/$(uname -m)" in Linux/aarch64|Linux/arm64) QEMU=" ";; esac

run_kat sha256_kat sha256
run_kat hmac_kat   sha256 hmac
run_kat aes_kat    aes
run_kat gcm_kat    aes gcm
run_kat x25519_kat x25519
run_kat sha512_kat sha512
run_kat bignum_kat bignum
run_kat rsa_kat    sha256 sha512 bignum rsa
run_kat ecdsa_kat  bignum ecdsa
run_kat ecdh_kat   bignum ecdsa ecdh
run_kat der_kat    der
run_kat x509_kat   sha256 sha512 bignum rsa ecdsa der x509
run_kat pem_kat    pem
# net_load_roots parses the trust store from the bytes read() returns, without
# decode(). PEM is ASCII, so the certificates have to come out the same either
# way. This checks that on the host's own bundle, where it keeps one in a file.
bundle=/etc/ssl/certs/ca-certificates.crt
if [ -r "$bundle" ]; then
  { echo "import sys"; python3 "$root/dev/toolchain/netlib_cat.py" pem
    cat <<EOF
raw = read("$bundle")
a = pem_certs(raw)
b = pem_certs(decode(raw))
same = len(a) > 0 && len(a) == len(b)
i = 0
loop i < len(a) && same
    if a[i] != b[i]
        same = false
    i = i + 1
if same
    out("pem (word): the host bundle's " . len(a) . " certificates are the same from its bytes as from its text")
    return 0
err("  FAIL: pem_certs over " . "$bundle" . " differs between the bytes and the text")
return 1
EOF
  } > "$tmp/app.w"
  if "$WORD" build "$tmp/app.w" -o "$tmp/kat" >"$tmp/err" 2>&1; then
    "$tmp/kat" || fail=$((fail+1))
  else
    echo "  FAIL: the host bundle check did not build"; sed 's/^/    /' "$tmp/err"; fail=$((fail+1))
  fi
fi
run_kat chacha20_kat chacha20
run_kat poly1305_kat chacha20 poly1305
run_kat tls_kat    sha256 sha512 hmac bignum rsa ecdsa ecdh der x509 chacha20 poly1305 aes gcm x25519 tls
run_kat dns_kat    dns
# Capped at 256 MB: its last vector decodes a 16 MiB chunked body, which has to
# cost one copy of the body instead of a copy per chunk.
CAP=262144
run_kat http_kat   http
CAP=

[ "$fail" = 0 ] || { echo "test_crypto_w: FAIL=$fail"; exit 1; }
echo "test_crypto_w: PASS"
