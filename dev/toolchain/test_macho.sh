#!/bin/sh
# test_macho.sh: structural checks on the Mach-O writer.
#
# Nothing here runs a macOS binary: the suite runs on Linux, and reads the
# images with llvm-objdump and a few python3 checks. Running the output needs
# an Apple Silicon host, which the macos-arm-run job in macos.yml has (a
# macos-14 runner).
#
# The same checks run on what `word build -mac` produces and on the image
# macho_ref.py generates, a reference whose layout was compared with lld's
# (`lld -flavor darwin`) output. The writer was transcribed from the
# reference, so a difference is a bug in one of them.
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/../.." && pwd); cd "$root"
command -v llvm-objdump >/dev/null 2>&1 || { echo "test_macho: SKIP (no llvm-objdump)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "test_macho: SKIP (no python3)"; exit 0; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

check_image() {   # $1 = path, $2 = what it is
  img="$1"; what="$2"
# 1. llvm-objdump parses every load command without complaint.
if llvm-objdump --macho --all-headers "$img" > "$tmp/h.txt" 2>"$tmp/e.txt" && [ ! -s "$tmp/e.txt" ]; then
  ok "$what: llvm-objdump reads the header and every load command"
else bad "$what: llvm-objdump rejected the image"; sed 's/^/    /' "$tmp/e.txt"; fi

# 2. the four segments have the right permissions, and none is both writable
#    and executable.
for pair in "__PAGEZERO:---" "__TEXT:r-x" "__RODATA:r--" "__DATA:rw-"; do
  seg=${pair%%:*}; prot=${pair#*:}
  if grep -A6 "segname $seg\$" "$tmp/h.txt" | grep -q "initprot $prot"; then
    ok "$what: $seg is $prot"
  else bad "$what: $seg is not $prot; no segment may be both writable and executable"; fi
done

# 3. no two segments may overlap in memory. A program with no initialized data
#    used to put __DATA and __LINKEDIT at the same address, which llvm-objdump
#    accepts and the kernel refuses to run.
python3 - "$img" <<'EOF' && ok "$what: no two segments overlap in memory" || bad "$what: segments overlap"
import struct, sys
d = open(sys.argv[1], 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off, segs = 32, []
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        nm = d[off+8:off+24].rstrip(b'\0').decode()
        vm, vs, fo, fs = struct.unpack_from('<QQQQ', d, off+24)
        if nm != '__PAGEZERO' and vs:
            segs.append((vm, vm + vs, nm))
    off += sz
segs.sort()
for (a0, a1, an), (b0, b1, bn) in zip(segs, segs[1:]):
    if b0 < a1:
        raise SystemExit("%s [%#x,%#x) overlaps %s [%#x,%#x)" % (an, a0, a1, bn, b0, b1))
EOF

# 4. the entry is an LC_MAIN, with LC_LOAD_DYLINKER. An image without dyld
#    doesn't run on Apple Silicon (on a macos-14 runner, Apple's own
#    `ld -static` output was killed the same way word's was), so dyld maps the
#    image. It must load nothing else: no LC_LOAD_DYLIB means no libc, no dylib
#    and no outside initializer.
grep -q "cmd LC_MAIN" "$tmp/h.txt" && ok "$what: entry is LC_MAIN" || bad "$what: no LC_MAIN"
grep -q "LC_LOAD_DYLINKER" "$tmp/h.txt" && ok "$what: dyld maps the image" || bad "$what: no LC_LOAD_DYLINKER"
grep -q "cmd LC_UNIXTHREAD" "$tmp/h.txt" && bad "$what: LC_UNIXTHREAD; a dyld-less image will not run" || ok "$what: no LC_UNIXTHREAD"
grep -q "cmd LC_LOAD_DYLIB" "$tmp/h.txt" && bad "$what: LC_LOAD_DYLIB; word links no library" || ok "$what: no dylib is linked"
grep -q "cmd LC_LOAD_WEAK_DYLIB\|LC_REEXPORT_DYLIB\|LC_LOAD_UPWARD_DYLIB" "$tmp/h.txt" \
  && bad "$what: another dylib load command" || ok "$what: nothing else is loaded either"

# 5. the ad-hoc signature: every page hash matches the file, and codeLimit stops
#    where the signature starts.
python3 - "$img" <<'EOF' && ok "$what: ad-hoc signature verifies over every 4 KiB page" || bad "$what: the code signature does not verify"
import struct, hashlib, sys
d = open(sys.argv[1], 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off, sig = 32, None
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x1d: sig = struct.unpack_from('<II', d, off + 8)
    off += sz
assert sig, "no LC_CODE_SIGNATURE: the Apple Silicon kernel will not run this"
do, ds = sig
sb = d[do:do + ds]
assert struct.unpack_from('>I', sb, 0)[0] == 0xfade0cc0, "not a SuperBlob"
o2 = struct.unpack_from('>I', sb, 16)[0]
m, _l, _v, fl, hoff, ioff, _ns, ncode, climit, hsize, htype, _p, pglog, _s = \
    struct.unpack_from('>IIIIIIIIIBBBBI', sb, o2)
assert m == 0xfade0c02, "not a CodeDirectory"
assert fl & 2, "the adhoc flag is not set"
assert htype == 2 and hsize == 32, "hashes must be SHA-256"
assert pglog == 12, "the signature hashes 4 KiB pages whatever the segment alignment is"
assert climit == do, "codeLimit must stop where the signature starts"
# A CodeDirectory's header length is fixed by its declared version, and
# llvm-objdump doesn't notice a wrong one. codesign then reads the identifier
# from the middle of the header and says "code object is not signed at all",
# and the kernel kills the process.
need = {0x20100: 48, 0x20200: 52, 0x20300: 64, 0x20400: 88}.get(_v)
assert need, "unknown CodeDirectory version %08x" % _v
assert ioff == need, ("version %08x needs a %d-byte header, identOffset is %d"
                      % (_v, need, ioff))
assert hoff == ioff + len(sb[o2 + ioff:sb.index(b"\0", o2 + ioff)]) + 1, \
    "hashOffset must follow the identifier"
if _v >= 0x20400:
    base, limit, eflags = struct.unpack_from(">QQQ", sb, o2 + 64)
    assert eflags & 1, "execSegFlags must mark this the main binary"
    assert limit > 0, "execSegLimit must cover __TEXT"
for i in range(ncode):
    want = sb[o2 + hoff + i * 32: o2 + hoff + (i + 1) * 32]
    if hashlib.sha256(d[i * 4096:(i + 1) * 4096]).digest() != want:
        raise SystemExit("page %d hash mismatch" % i)
EOF

# 6. the signature is inside __LINKEDIT, the last segment, which runs to the
#    end of the file. A blob in a hole that no segment covers parses fine but
#    isn't a loadable image. The image also has to declare the platform it was
#    built for (LC_BUILD_VERSION, macOS).
python3 - "$img" <<'EOF' && ok "$what: signature is inside __LINKEDIT, and the platform is declared" || bad "$what: __LINKEDIT / LC_BUILD_VERSION"
import struct, sys
d = open(sys.argv[1], 'rb').read()
ncmds = struct.unpack_from('<I', d, 16)[0]
off, segs, sig, plat = 32, {}, None, None
for _ in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:
        nm = d[off+8:off+24].rstrip(b'\0').decode()
        segs[nm] = struct.unpack_from('<QQQQ', d, off+24)   # vmaddr vmsize fileoff filesize
    elif cmd == 0x1d: sig = struct.unpack_from('<II', d, off + 8)
    elif cmd == 0x32: plat = struct.unpack_from('<I', d, off + 8)[0]
    off += sz
assert sig, "no LC_CODE_SIGNATURE"
assert '__LINKEDIT' in segs, "no __LINKEDIT segment to hold the signature"
vm, vs, fo, fs = segs['__LINKEDIT']
assert fo <= sig[0] and sig[0] + sig[1] <= fo + fs, \
    "the signature at %d+%d is not inside __LINKEDIT at %d+%d" % (sig[0], sig[1], fo, fs)
assert sig[0] + sig[1] == len(d), "the signature must end at the end of the file"
top = max(v[0] + v[1] for k, v in segs.items() if k != '__PAGEZERO')
assert vm + vs == top, "__LINKEDIT must be the last segment in memory"
assert plat == 1, "LC_BUILD_VERSION must declare platform 1 (macOS), got %r" % plat
EOF
}

python3 "$here/macho_ref.py" "$tmp/ref"
check_image "$tmp/ref" "reference"

# and the real thing: what the compiler emits for -mac.
printf 'out("hello from word on macOS")\n' > "$tmp/hello.w"
if ./word build -mac "$tmp/hello.w" -o "$tmp/hello" 2>"$tmp/be.txt"; then
  check_image "$tmp/hello" "word build -mac"
else
  bad "word build -mac failed"; sed 's/^/    /' "$tmp/be.txt"
fi

# The Darwin shim is reached with `bl`, which writes x30, and not every syscall
# site is inside a function that saved it (rt_now is a leaf: `sub sp` ...
# `ret`, with no stp of x29/x30). a64_svc brackets every call with a save and
# restore, so the site's own prologue doesn't matter. Losing that would only
# show up when the affected builtin ran on a Mac, so this disassembles a
# program, finds the shim and checks that every call into it is bracketed.
printf 'out("t" . now())\nout("r" . random())\nout(read("/etc/hostname"))\n' > "$tmp/sv.w"
if ./word build -mac "$tmp/sv.w" -o "$tmp/sv" 2>/dev/null && llvm-objdump --macho -d "$tmp/sv" > "$tmp/sv.txt" 2>/dev/null; then
  python3 - "$tmp/sv.txt" <<'EOF' && ok "every call into the Darwin shim preserves x30" || bad "a bl into m_syscall does not preserve x30"
import re, sys
ins = []
for line in open(sys.argv[1]):
    m = re.match(r'^([0-9a-f]+):\s+(?:[0-9a-f]{2}\s+){4}(.*)$', line.strip())
    if m:
        ins.append((int(m.group(1), 16), ' '.join(m.group(2).split())))
at = {a: i for i, (a, _) in enumerate(ins)}
# m_syscall is the routine whose first instruction loads the exit number, 93.
shim = [a for a, t in ins if t.replace('0x5d', '93') == 'mov x9, #93']
if not shim:
    raise SystemExit("no m_syscall found: the check would pass vacuously")
shim = shim[0]
calls = [i for i, (a, t) in enumerate(ins) if t == 'bl %#x' % shim]
if not calls:
    raise SystemExit("no call into m_syscall found: the check would pass vacuously")
for i in calls:
    before, after = ins[i-1][1], ins[i+1][1]
    if 'str x30, [sp, #-0x10]!' not in before or 'ldr x30, [sp], #0x10' not in after:
        raise SystemExit("bl at %#x is not bracketed: %r / %r" % (ins[i][0], before, after))
print("  (%d calls into the shim, all bracketed)" % len(calls))
EOF
else
  bad "could not build or disassemble a macOS binary that makes syscalls"
fi

[ "$fail" = 0 ] || { echo "test_macho: FAIL=$fail"; exit 1; }
echo "test_macho: PASS"
