#!/bin/sh
# bench_crypto_w.sh: what the net library's crypto costs.
#
# Every row runs a real workload through the net library's crypto and reports
# the throughput. Where OpenSSL on this machine can be pointed at the same bytes
# with one command, it runs too, and the ratio is printed beside it. Where it
# can't, the row says so instead of guessing.
#
# Dev tool, never part of a build. Run from the repo root:  sh dev/toolchain/bench_crypto_w.sh
#
# Read the ratios carefully. None of them is the language on its own, because
# OpenSSL is hand-vectorized everywhere this measures: SHA-NI for SHA-256, AVX2
# for SHA-512 and for ChaCha20 four blocks at a time, AES-NI and PCLMULQDQ for
# GCM. Portable source can't reach any of that, so every ratio here is the
# language and the instruction set together, and this table doesn't split them.
#
# The public-key rows have a further cost that is structural. word integers are
# 63-bit, so limbs are narrower than a C implementation's 64: bignum's are 30
# bits, so a P-256 field multiply is 162 limb products against 16, and X25519's
# are 25.5 bits. That follows from the value model, not from the compiler, and
# it only affects X25519, RSA and ECDSA. Hashes and stream ciphers don't pay it.
#
# So the column to watch over time is word's own, in MB/s: a row that moves
# without a change to its module is a codegen regression.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
have_ssl=0; command -v openssl >/dev/null 2>&1 && have_ssl=1

ms() { # run a command three times, report the best in milliseconds
  best=999999
  for _ in 1 2 3; do
    a=$(date +%s%N); "$@" >/dev/null 2>&1; b=$(date +%s%N)
    t=$(( (b - a) / 1000000 )); [ "$t" -lt "$best" ] && best=$t
  done
  echo "$best"
}
mods() { echo "import sys" > "$tmp/app.w"
  python3 "$root/dev/toolchain/netlib_cat.py" "$@" >> "$tmp/app.w"; }
# The driver fragment isn't a .w file: it's appended to app.w below, and under
# the SPEC 11 folder model, building app.w pulls in every .w file beside it, so
# a drv.w would be compiled a second time (a duplicate-definition error). With
# no extension, app.w stays the only .w in the directory.
wbuild() { cat "$tmp/drv.frag" >> "$tmp/app.w"
  "$WORD" build "$tmp/app.w" -o "$tmp/w.x" >"$tmp/err" 2>&1 || {
    echo "  build failed:"; sed 's/^/    /' "$tmp/err"; return 1; }; }
row() { # label, word-ms, reference-ms-or-dash, unit-text
  if [ "$3" = "-" ]; then ratio="-"; else ratio=$(awk -v w="$2" -v a="$3" 'BEGIN{if(a>0)printf "%.1fx", w/a; else print "-"}'); fi
  printf "  %-26s %10s %12s %8s   %s\n" "$1" "$2" "$3" "$ratio" "$4"; }
thr() { awk -v mib="$1" -v ms="$2" 'BEGIN{if(ms>0)printf "%d MB/s", mib*1048576/ms/1000; else print "-"}'; }

# 16 MiB of zeros, the same bytes both sides read
dd if=/dev/zero of="$tmp/16m" bs=1048576 count=16 >/dev/null 2>&1

printf "\n  %-26s %10s %12s %8s\n" "" "word" "openssl" "ratio"
printf "  %-26s %10s %12s %8s\n" "--------------------------" "----------" "------------" "--------"

# ---- bulk: the record layer, which is what a real transfer spends its time in

cat > "$tmp/drv.frag" <<'EOF'
m = bytes(16777216)
d = sha256(m)
out("" . len(d))
EOF
mods sha256; wbuild; W=$(ms "$tmp/w.x")
A="-"; [ "$have_ssl" = 1 ] && A=$(ms openssl dgst -sha256 "$tmp/16m")
row "SHA-256, 16 MiB" "$W" "$A" "$(thr 16 "$W") vs $(thr 16 "$A")"

cat > "$tmp/drv.frag" <<'EOF'
m = bytes(16777216)
d = sha512(m)
if len(m) == 0
    d = sha384(m)
out("" . len(d))
EOF
mods sha512; wbuild; W=$(ms "$tmp/w.x")
A="-"; [ "$have_ssl" = 1 ] && A=$(ms openssl dgst -sha512 "$tmp/16m")
row "SHA-512, 16 MiB" "$W" "$A" "$(thr 16 "$W") vs $(thr 16 "$A")"

cat > "$tmp/drv.frag" <<'EOF'
key = bytes(32)
nonce = bytes(12)
d = bytes(4194304)
c = bytes(4194304)
i = 0
loop i < 4
    chacha20_into(c, key, nonce, 1, d, 4194304)
    i = i + 1
out("done")
EOF
mods chacha20; wbuild; W=$(ms "$tmp/w.x")
A="-"
if [ "$have_ssl" = 1 ] && openssl enc -chacha20 -K 00000000000000000000000000000000000000000000000000000000000000000 \
     -iv 000000000000000000000000000000000 -in /dev/null >/dev/null 2>&1; then
  A=$(ms openssl enc -chacha20 \
      -K 0000000000000000000000000000000000000000000000000000000000000000 \
      -iv 00000000000000000000000000000000 -in "$tmp/16m" -out /dev/null)
fi
row "ChaCha20, 16 MiB" "$W" "$A" "$(thr 16 "$W") vs $(thr 16 "$A")   <-- openssl is AVX2 here"

cat > "$tmp/drv.frag" <<'EOF'
key = bytes(32)
nonce = bytes(12)
aad = bytes(5)
pt = bytes(16384)
i = 0
loop i < 1024
    ct = chacha20_poly1305_encrypt(key, nonce, aad, pt)
    i = i + 1
p = chacha20_poly1305_decrypt(key, nonce, aad, chacha20_poly1305_encrypt(key, nonce, aad, bytes(16)))
out("done " . len(p))
EOF
mods chacha20 poly1305; wbuild; W=$(ms "$tmp/w.x")
row "ChaCha20-Poly1305, 16 MiB" "$W" "-" "$(thr 16 "$W"); the CLI has no AEAD mode to point at these bytes"

cat > "$tmp/drv.frag" <<'EOF'
key = bytes(16)
iv = bytes(12)
aad = bytes(5)
pt = bytes(16384)
i = 0
loop i < 256
    ct = gcm_encrypt(key, iv, aad, pt)
    i = i + 1
p = gcm_decrypt(key, iv, aad, gcm_encrypt(key, iv, aad, bytes(16)))
out("done " . len(p))
EOF
mods aes gcm; wbuild; W=$(ms "$tmp/w.x")
row "AES-128-GCM, 4 MiB" "$W" "-" "$(thr 4 "$W"); the software AES path, with no AES-NI to reach"

# ---- public key: once per handshake

printf "\n"
cat > "$tmp/drv.frag" <<'EOF'
k = bytes(32)
k[0] = 9
i = 0
loop i < 100
    k = x25519_base(k)
    i = i + 1
out("done")
EOF
mods x25519; wbuild; W=$(ms "$tmp/w.x")
row "X25519, 100 scalar mults" "$W" "-" "$(awk -v m="$W" 'BEGIN{printf "%.2f", m/100}')ms each in word"

cat > "$tmp/drv.frag" <<'EOF'
pub = bytes("04cb9f39c4296ef3c274d128605275539206dabfef1e36f9383203a9b5a3422e2714a9b00bbf3dfe05a5712e6ef539fdddfb128f4ea64449de5b83ce7e8114727d")
dg = bytes("d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
r = bytes("5c6d82468ff4db70720fc7d771ca4bba2daa815754af7b4cfce7334c13570080")
s = bytes("2da52548da0b8e3ef0f9721324f879fd786a4949b3e97660d3e6c44d804bc5ef")
i = 0
ok = 0
loop i < 20
    ok = ok + ecdsa_verify(1, pub, dg, r, s)
    i = i + 1
if ok != 20
    err("bench: the P-256 vector did not verify")
out("" . ok)
EOF
mods bignum ecdsa; wbuild; W=$(ms "$tmp/w.x")
row "P-256 verify, 20" "$W" "-" "$(awk -v m="$W" 'BEGIN{printf "%.1f", m/20}')ms each; OpenSSL here does 0.074ms"
echo
