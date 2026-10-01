#!/bin/sh
# test_bigio.sh: fs.read and fs.write have no size cap. A 3 MB file goes
# through a word program (read, then write) and has to come back
# byte-identical. The old fixed 1 MB file buffer cut it off at 1 MB.
#
# Text goes the other way too: a word-backed text of 3,000,000 UTF-8 bytes, a
# mix of 1-, 2-, 3- and 4-byte characters, is written and then appended, and
# the file has to be exactly its UTF-8 twice over. The encoder fills a 1 MB
# buffer at a time, so the buffer edges fall in the middle of the mix. write()
# used to keep only the low byte of each code point. The text half runs on
# x86-64 and, under qemu, arm64, since each runtime has its own encoder.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

# 3 MB of random bytes
dd if=/dev/urandom of="$tmp/in.bin" bs=1024 count=3072 >/dev/null 2>&1

cat > "$tmp/roundtrip.w" <<'EOF'
import fs
a = args()
s = read(a[1])
ok = write(a[2], s)
out(len(s))
EOF

"$WORD" build "$tmp/roundtrip.w" -o "$tmp/roundtrip" >/dev/null 2>&1
got=$("$tmp/roundtrip" "$tmp/in.bin" "$tmp/out.bin")
want=$(wc -c < "$tmp/in.bin")

fail=0
if [ "$got" = "$want" ] && cmp -s "$tmp/in.bin" "$tmp/out.bin"; then
  echo "  ok: read then write round-trips $want bytes, byte-identical, well over the old 1 MB cap"
else
  echo "  FAIL: read len=$got want=$want; cmp: $(cmp "$tmp/in.bin" "$tmp/out.bin" 2>&1)"; fail=1
fi

# "a", U+00E9, U+20AC and U+1F600: 10 bytes of UTF-8 for every 4 code points.
cat > "$tmp/text.w" <<'EOF'
import fs
a = args()
s = ""
i = 0
loop i < 300000
    s = s . "a" . char(233) . char(8364) . char(128512)
    i = i + 1
out(write(a[1], s) . " " . append(a[1], s))
EOF
awk 'BEGIN { s = "a\303\251\342\202\254\360\237\230\200"; for (i = 0; i < 600000; i++) printf "%s", s }' > "$tmp/want.txt"

text_check() { # text_check <label> <command...>: it is handed the file to write
  label=$1; shift
  rm -f "$tmp/text.out"
  got=$("$@" "$tmp/text.out" 2>&1) || true
  if [ "$got" = "true true" ] && cmp -s "$tmp/want.txt" "$tmp/text.out"; then
    echo "  ok: $label: 3,000,000 bytes of text written and appended as UTF-8, byte-identical"
  else
    echo "  FAIL: $label: printed [$got], $(wc -c < "$tmp/text.out" 2>/dev/null || echo no) bytes; cmp: $(cmp "$tmp/want.txt" "$tmp/text.out" 2>&1 | head -1)"; fail=1
  fi
}
if "$WORD" build "$tmp/text.w" -o "$tmp/text" >"$tmp/err" 2>&1; then
  text_check x86-64 "$tmp/text"
else echo "  FAIL: x86-64 build of text.w"; sed 's/^/    /' "$tmp/err"; fail=1; fi

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
case "$(uname -m)" in aarch64|arm64) QEMU=" ";; esac
if [ -n "$QEMU" ]; then
  if "$WORD" build -arm64 "$tmp/text.w" -o "$tmp/text.a64" >"$tmp/err" 2>&1; then
    text_check arm64 $QEMU "$tmp/text.a64"
  else echo "  FAIL: arm64 build of text.w"; sed 's/^/    /' "$tmp/err"; fail=1; fi
else
  echo "  skip: no qemu-aarch64, the arm64 encoder is not exercised"
fi

if [ "$fail" = 0 ]; then
  echo "test_bigio: PASS (round-tripped $want bytes, and 3,000,000 bytes of text on every target checked)"
  exit 0
fi
echo "test_bigio: FAIL"
exit 1
