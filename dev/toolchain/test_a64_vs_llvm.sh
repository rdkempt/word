#!/bin/sh
# test_a64_vs_llvm.sh: the AArch64 encoder oracle. word's own assembler
# (`word asm -arm64`) against llvm-mc, instruction for instruction, over
# a64_corpus.txt plus every logical immediate the encoding can express.
# llvm-mc is only a cross-check for development and CI; word never needs it to
# build or run. This is the AArch64 half of test_encoder_vs_as.sh.
#
# Both sides assemble the same file with a `nop` after each corpus line. If the
# two disagree about how many instructions a line is, the streams line up again
# at the next nop, so the line shows up as one difference and the lines after
# it still line up.
#
# The corpus lines llvm-mc rejects are `mov xd, #imm` with an immediate too
# wide for one instruction, which word expands to MOVZ + MOVK. That's an
# extension (like x86-64's `mov r64, imm64`), so llvm-mc can't judge it. These
# lines are counted separately here and checked by running them in
# test_a64_run.sh.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}

# Distributions often ship llvm-mc with a version suffix, and Debian and Ubuntu
# put it under /usr/lib/llvm-*/bin.
MC=$(command -v llvm-mc || true)
if [ -z "$MC" ]; then
  for c in $(ls /usr/bin/llvm-mc-* /usr/lib/llvm-*/bin/llvm-mc 2>/dev/null | sort -V -r); do
    [ -x "$c" ] && { MC=$c; break; }
  done
fi
[ -n "$MC" ] || { echo "SKIP: llvm-mc not found (encoder oracle is dev/CI-only)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not on PATH"; exit 0; }
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Every value the logical-immediate encoding can express: a run of `cnt` ones in
# an element of `size` bits, rotated by `r`, repeated to fill the register.
# That's 5334 values at 64 bits and 1302 at 32. The list is generated because
# it's mechanical, and llvm-mc is the oracle: a value the generator got wrong is
# one llvm-mc rejects, and that fails the suite.
python3 - > "$tmp/gen.txt" <<'PYEOF'
def sweep(width):
    vals = set()
    size = 2
    while size <= width:
        for cnt in range(1, size):
            elem = (1 << cnt) - 1
            for r in range(size):
                e = ((elem >> r) | (elem << (size - r))) & ((1 << size) - 1) if r else elem
                v = 0
                for k in range(0, width, size):
                    v |= e << k
                vals.add(v)
        size *= 2
    return sorted(vals)
out = ["and x0, x1, #0x%x" % v for v in sweep(64)]
out += ["orr w0, w1, #0x%x" % v for v in sweep(32)]
print("\n".join(out))
PYEOF

compare() {
  corpus="$1"; label="$2"
  awk '{print; print "nop"}' "$corpus" > "$tmp/body.s"
  { echo ".text"; cat "$tmp/body.s"; } > "$tmp/all.s"
  "$MC" -triple=aarch64 -show-encoding "$tmp/all.s" 2>"$tmp/lerr" \
    | grep -o 'encoding: \[[^]]*\]' | sed 's/encoding: \[//; s/\]//; s/0x//g; s/, */ /g' > "$tmp/llvm.txt"
  { echo ".text"; echo ".global _start"; echo "_start:"; cat "$tmp/body.s"; } > "$tmp/w.s"
  if ! "$WORD" asm -arm64 "$tmp/w.s" "$tmp/w.bin" >"$tmp/werr" 2>&1; then
    echo "FAIL: word asm -arm64 errored on $label:"; head -3 "$tmp/werr"; return 1
  fi
  python3 - "$tmp/w.bin" "$tmp/llvm.txt" "$corpus" "$tmp/lerr" "$label" <<'PYEOF'
import re, sys
NOP = "1f2003d5"
# word's ELF has no section headers; .text always begins at file offset 4096.
img = open(sys.argv[1], 'rb').read()[4096:]
words = [img[i:i+4].hex() for i in range(0, len(img), 4)]
llvm = ["".join(l.split()) for l in open(sys.argv[2]) if l.split()]
def groups(ws):
    g = []; cur = []
    for w in ws:
        if w == NOP: g.append(cur); cur = []
        else: cur.append(w)
    return g
src = [l.rstrip('\n') for l in open(sys.argv[3]) if l.strip()]
# One group per corpus line. A corpus line that is itself `nop` encodes to the
# separator, so it ends a group of its own and the separator after it ends
# another: it takes two groups. Counting it as one would shift every later line
# by one in both streams, and a line llvm-mc rejects (recorded by corpus line)
# would then be compared against the wrong group.
def aligned(ws):
    g = groups(ws); res = []; k = 0
    for line in src:
        if line.strip() == "nop":
            both = k + 1 < len(g) and not g[k] and not g[k + 1]
            res.append([NOP] if both else ["?"]); k += 2
        else:
            res.append(g[k] if k < len(g) else None); k += 1
    return res
gw = aligned(words); gl = aligned(llvm)
# llvm-mc reports "<file>:LINE:COL: error:". The body has a nop after every
# corpus line, so corpus line i is file line 2i+2 (after a leading .text).
rejected = {}
for line in open(sys.argv[4]):
    m = re.match(r'.*?:(\d+):\d+: error: (.*)', line)
    if m:
        fl = int(m.group(1))
        if (fl - 2) % 2 == 0: rejected[(fl - 2) // 2] = m.group(2)
ok = bad = 0; msgs = []; ext = []
for i, line in enumerate(src):
    if gl[i] is None or gw[i] is None:
        print("FAIL: %s: stream ended after %d of %d lines" % (sys.argv[5], i, len(src)))
        sys.exit(1)
    if i in rejected and not gl[i]:
        ext.append((line, " ".join(gw[i]))); continue
    if gw[i] == gl[i]: ok += 1
    else:
        bad += 1
        if len(msgs) < 12:
            msgs.append("  DIFF %-34s word=%-24s llvm=%s" % (line, " ".join(gw[i]), " ".join(gl[i])))
if msgs: print("\n".join(msgs))
tail = ""
if ext:
    tail = ", %d word-only (wide mov, see test_a64_run.sh)" % len(ext)
    for line, w in ext:
        if not line.lstrip().startswith("mov"):
            print("  FAIL llvm-mc rejected a line that is not a wide mov: %s" % line)
            bad += 1
print("%s: %d ok, %d differ%s" % (sys.argv[5], ok, bad, tail))
sys.exit(1 if bad else 0)
PYEOF
}

compare "$here/a64_corpus.txt" "a64 corpus vs llvm-mc"
compare "$tmp/gen.txt" "every logical immediate vs llvm-mc"

# A value that isn't a logical immediate has to be refused. Encoding the
# nearest legal pattern instead would apply a different mask from the one
# written, and the result would still look like a valid number.
bad=0; n=0
for v in 0x0 0xffffffffffffffff 0x5555555555555554 0xaaaaaaaaaaaaaaab \
         0x123456789abcdef0 0x7 0xf0f0f0f0f0f0f0f1 0x8000000000000005; do
  case "$v" in 0x7) want=ok;; *) want=reject;; esac
  n=$((n+1))
  printf '.text\n.global _start\n_start:\n    and x0, x1, #%s\n' "$v" > "$tmp/one.s"
  if "$WORD" asm -arm64 "$tmp/one.s" "$tmp/one.bin" 2>&1 | grep -q "not a logical immediate"; then
    got=reject
  else
    got=ok
  fi
  [ "$got" = "$want" ] || { echo "  FAIL: and x0, x1, #$v -> $got (want $want)"; bad=$((bad+1)); }
done
echo "non-immediates refused: $n checked, $bad wrong"
[ "$bad" = 0 ]
