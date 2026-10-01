#!/bin/sh
# test_elf.sh: the ELF word writes, read back as a container.
#
# test_win_pe.sh checks the structure of word's PE output: W^X sections, the NX
# and ASLR flags, a real checksum. The ELF side had three page-aligned PT_LOAD
# segments (instead of one RWX one) and no test for them, only a comment in
# the linker. This is that test, plus the header the layout was missing.
#
# PT_GNU_STACK is the addition. word never puts code on the stack, but an ELF
# that doesn't say so leaves the stack permission to the loader's default,
# which GNU ld documents as target-dependent. checksec and distribution
# hardening checks treat a missing header as a defect for that reason. It maps
# nothing and costs 56 bytes.
#
# Everything here reads word's own output with python3: no readelf, no
# binutils, nothing that has to be installed to build word.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd)
# word.exe is a native Windows binary when this runs on Windows, and cannot open
# an MSYS path. One conversion here keeps every line below it working on both.
. "$here/hostpath.sh"; here=$(hostpath "$here"); root=$(hostpath "$root")
cd "$root"
WORD=$(wordbin "${WORD:-$root/word}")
[ -x "$WORD" ] || { echo "FAIL: no word binary at $WORD"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "test_elf: SKIP (no python3)"; exit 0; }

tmp=$(hostpath "$(mktemp -d)"); trap 'rm -rf "$tmp"' EXIT
fail=0

printf 'out("hi")\n' > "$tmp/hello.w"
"$WORD" build -linux "$tmp/hello.w" -o "$tmp/hello" || { echo "FAIL: could not build for -linux"; exit 1; }
"$WORD" build -arm64 "$tmp/hello.w" -o "$tmp/hello.a64" || { echo "FAIL: could not build for -arm64"; exit 1; }

check() { # check <label> <file> <want-e_machine>
  python3 - "$2" "$3" <<'PYEOF' && echo "  ok: $1" || { echo "  FAIL: $1 (see above)"; fail=1; }
import struct, sys
d = open(sys.argv[1], 'rb').read()
want_machine = int(sys.argv[2])
bad = []

if d[:4] != b'\x7fELF':
    print("    not an ELF"); sys.exit(1)
if d[4] != 2: bad.append("not ELFCLASS64")
if d[5] != 1: bad.append("not ELFDATA2LSB")
machine, = struct.unpack_from('<H', d, 18)
if machine != want_machine:
    bad.append("e_machine is %d, want %d" % (machine, want_machine))

e_phoff,           = struct.unpack_from('<Q', d, 32)
e_phentsize, e_phnum = struct.unpack_from('<HH', d, 54)
if e_phentsize != 56:
    bad.append("e_phentsize is %d, want 56" % e_phentsize)

PT_LOAD, PT_GNU_STACK = 1, 0x6474e551
PF_X, PF_W, PF_R = 1, 2, 4
loads, gnustack = [], None
for i in range(e_phnum):
    o = e_phoff + i * e_phentsize
    ptype, flags = struct.unpack_from('<II', d, o)
    off, vaddr, paddr, filesz, memsz, align = struct.unpack_from('<QQQQQQ', d, o + 8)
    if ptype == PT_LOAD:
        loads.append((flags, off, vaddr, filesz, memsz, align))
    elif ptype == PT_GNU_STACK:
        gnustack = flags

# W^X: no loadable segment may be both writable and executable.
for flags, off, vaddr, filesz, memsz, align in loads:
    if (flags & PF_W) and (flags & PF_X):
        bad.append("a PT_LOAD is both writable and executable (p_flags=%#x)" % flags)
    if align != 4096:
        bad.append("a PT_LOAD has p_align %d, want 4096" % align)

if len(loads) != 3:
    bad.append("%d PT_LOAD segments, want 3 (R-X text, R-- rodata, RW- data+bss)" % len(loads))
else:
    perms = [f & 7 for f, *_ in loads]
    if perms != [PF_R | PF_X, PF_R, PF_R | PF_W]:
        bad.append("PT_LOAD permissions are %s, want [R-X, R--, RW-]" % [oct(p) for p in perms])
    # ascending p_vaddr, which the ELF spec requires of PT_LOAD
    vas = [v for _, _, v, _, _, _ in loads]
    if vas != sorted(vas):
        bad.append("PT_LOAD segments are not in ascending p_vaddr order: %s" % [hex(v) for v in vas])
    # and the rodata segment must not be writable
    if loads[1][0] & PF_W:
        bad.append("the rodata segment is writable")

# PT_GNU_STACK: present, readable, writable, not executable.
if gnustack is None:
    bad.append("no PT_GNU_STACK, so the stack permission is the loader's default rather than this file's statement")
else:
    if gnustack & PF_X:
        bad.append("PT_GNU_STACK is executable (p_flags=%#x)" % gnustack)
    if (gnustack & (PF_R | PF_W)) != (PF_R | PF_W):
        bad.append("PT_GNU_STACK is not RW (p_flags=%#x)" % gnustack)

for b in bad:
    print("    " + b)
sys.exit(1 if bad else 0)
PYEOF
}

echo "== the ELF container word writes =="
check "x86-64: W^X PT_LOADs, and a non-executable PT_GNU_STACK" "$tmp/hello" 62
check "arm64:  the same, from the same source"                  "$tmp/hello.a64" 183

# The committed binary is an ELF word wrote, so the same rules apply to it, and
# it's the one that matters to someone who downloads a release.
echo
echo "== and the committed word binary itself =="
if [ "$(head -c 4 "$root/word" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
  check "the seed binary at the repository root" "$root/word" 62
else
  echo "  SKIP: ./word is not an ELF on this checkout"
fi

echo
[ "$fail" = 0 ] && echo "test_elf: OK" || echo "test_elf: FAILED"
exit $fail
