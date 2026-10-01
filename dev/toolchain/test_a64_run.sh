#!/bin/sh
# test_a64_run.sh: the AArch64 backend end to end. word assembles a64_run.s,
# links it into an ELF, and the ELF runs. qemu-user is only a test oracle, the
# way GNU as is in test_encoder_vs_as.sh; word itself doesn't need it.
#
# This covers what test_a64_vs_llvm.sh can't:
#   * the wide `mov` sequences llvm-mc rejects, so no encoding oracle can judge
#     them. The value that ends up in the register is the check.
#   * logical immediates whose 64-bit pattern doesn't fit one of word's 63-bit
#     integers (0x5555..., 0xaaaa...). An encoder that truncates them still
#     encodes something, with a different mask.
#   * branches, adr/adrp and the label relocations, whose bytes the linker
#     fills in, so they only mean something once laid out and run.
#   * .align padding in .text, which is only correct if running through it does
#     nothing (a zero word is UDF, and the x86 0x90 fill is some other
#     instruction on AArch64).
#   * the ELF itself: e_machine, the program headers, the entry point
#     (test_elf.sh checks the headers in detail, on both targets).
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
WORD=${WORD:-"$root/word"}
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

"$WORD" asm -arm64 "$here/a64_run.s" "$tmp/a64run" || { echo "FAIL: word asm -arm64 errored"; exit 1; }
chmod +x "$tmp/a64run"

# e_machine is checked first, since that needs nothing that can run the binary.
mach=$(od -An -tu1 -j18 -N1 "$tmp/a64run" | tr -d ' \n')
[ "$mach" = "183" ] || { echo "FAIL: e_machine is $mach, want 183 (EM_AARCH64)"; exit 1; }

QEMU=$(command -v qemu-aarch64-static || command -v qemu-aarch64 || true)
if [ -z "$QEMU" ]; then
  # On an actual arm64 host the binary just runs.
  case "$(uname -m)" in
    aarch64|arm64) QEMU=;;
    *) echo "SKIP: e_machine ok; no qemu-aarch64 to run it (dev/CI oracle only)"; exit 0;;
  esac
fi

rc=0
$QEMU "$tmp/a64run" > "$tmp/got.txt" 2>"$tmp/err.txt" || rc=$?
if [ "$rc" != 0 ]; then
  echo "FAIL: the AArch64 binary exited $rc"; head -5 "$tmp/err.txt"
  echo "  last lines printed:"; tail -3 "$tmp/got.txt"
  exit 1
fi

# One line per case, in the order a64_run.s prints them.
cat > "$tmp/want.txt" <<'EOF'
00000000000101d0
0000000000123456
0000000123456789
0000deadbeefcafe
1234000056780000
fedcba9876543210
0000000000000000
ffffffffffffffff
ffffffffffff0000
8000000000000001
0000000012345678
00000000fffffffe
5555555555555555
aaaaaaaaaaaaaaaa
0f0f0f0f0f0f0f0f
fffffffffffffff8
0000ffff0000ffff
7fffffffffffffff
0000000055555555
3333333333333333
0000000000002062
0000000000000036
0000001234567890
ffffffffffffffff
3400000000000012
4000000000000123
8877665544332211
11ee66aa22cc4488
0000000000000033
000000000000bcde
ffffffffffffffff
ffffffffffffffff
000000000000ffff
1234000000000000
000000e8d6ca6163
0000000000000000
fffffffffffdd1f7
249249249246f688
00000000000000cd
ffffffffffffff3d
000000000000000b
000000000000000b
ffffffffffffffea
ffffffffffffffff
000000000000000c
000000000000000b
1122334455667788
1122334455667788
1122334455667788
0000000000000048
1122334455667788
0000000000000088
0000000000007788
0000000000000088
0000000000000003
0000000000000037
0000000000000004
000000000000bef0
000000000000002a
0000000000000008
0123456789abcdef
0000000000000001
EOF

if diff -u "$tmp/want.txt" "$tmp/got.txt" > "$tmp/diff.txt"; then
  echo "a64 execution: $(wc -l < "$tmp/want.txt") values, all as expected"
else
  echo "FAIL: the AArch64 binary computed different values"; cat "$tmp/diff.txt"; exit 1
fi

# A conditional branch reaches +/-1 MB (b.cond, cbz, cbnz) or +/-32 KB (tbz,
# tbnz). Past that, `word asm` inverts the condition and branches over a plain
# `b`, the same relaxation a build does. It used to write a displacement of 0
# (a branch to itself) without an error, and the program hung. Every branch
# here is taken, so the program exits 7 if it reaches far and 1 if it doesn't.
far() { # label, branch line, "fwd" or "bwd", nops between
  if [ "$3" = fwd ]; then
    { printf '.text\n.global _start\n_start:\n    mov x0, #0\n    mov x1, #1\n    mov x2, #8\n    cmp x0, #0\n    %s\n    mov x0, #1\n    mov x8, #93\n    svc #0\n' "$2"
      awk -v n="$4" 'BEGIN{for(i=0;i<n;i++) print "    nop"}'
      printf 'far:\n    mov x0, #7\n    mov x8, #93\n    svc #0\n'; } > "$tmp/far.s"
  else
    { printf '.text\n.global _start\n_start:\n    b start2\nfar:\n    mov x0, #7\n    mov x8, #93\n    svc #0\n'
      awk -v n="$4" 'BEGIN{for(i=0;i<n;i++) print "    nop"}'
      printf 'start2:\n    mov x0, #0\n    mov x1, #1\n    mov x2, #8\n    cmp x0, #0\n    %s\n    mov x0, #1\n    mov x8, #93\n    svc #0\n' "$2"; } > "$tmp/far.s"
  fi
  rm -f "$tmp/far.elf"
  if ! "$WORD" asm -arm64 "$tmp/far.s" "$tmp/far.elf" > "$tmp/far.err" 2>&1; then
    echo "FAIL: $1: word asm -arm64 errored: $(head -1 "$tmp/far.err")"; farbad=1; return
  fi
  frc=0; timeout 20 $QEMU "$tmp/far.elf" || frc=$?
  if [ "$frc" = 7 ]; then farok=$((farok+1))
  else echo "FAIL: $1: exited $frc, want 7 (124 is a hang)"; farbad=1; fi
}
farok=0; farbad=0
far "b.eq forward 1.2 MB"   "b.eq far"         fwd 300000
far "cbz forward 1.2 MB"    "cbz x0, far"      fwd 300000
far "cbnz forward 1.2 MB"   "cbnz x1, far"     fwd 300000
far "tbz forward 40 KB"     "tbz x0, #0, far"  fwd 10000
far "tbnz forward 1.2 MB"   "tbnz x2, #3, far" fwd 300000
far "b.eq backward 1.2 MB"  "b.eq far"         bwd 300000
far "cbz backward 1.2 MB"   "cbz x0, far"      bwd 300000
far "tbz backward 40 KB"    "tbz x0, #5, far"  bwd 10000
[ "$farbad" = 0 ] || exit 1
echo "a64 branch relaxation: $farok out-of-range conditional branches reach"
