# macho_ref.py: a reference layout for link_macho() in compiler/word.w.
#
# A dev and CI oracle, never part of a build (word builds with word). It gives
# the Mach-O writer a known-good image to be checked beside, the way the
# AArch64 encoder has llvm-mc and the x86-64 one has GNU as. test_macho.sh runs
# the same structural checks on this file's image and on `word build -mac`, and
# macos.yml runs this file's images on a Mac, so a failure in word's image can
# be told apart from a change in macOS.
#
# It writes a minimal arm64 Mach-O executable with no libSystem and an ad-hoc
# code signature. The default 'dyld' mode loads dyld and nothing else
# (LC_LOAD_DYLINKER and LC_MAIN, no LC_LOAD_DYLIB) and has an empty symbol
# table. 'dyld-nosym' leaves the symbol table out. 'static' has no dyld and
# uses LC_UNIXTHREAD for the entry state (LC_MAIN needs dyld, which is what
# calls it).
#
# The signature is required. The Apple Silicon kernel SIGKILLs an unsigned
# arm64 binary, so a Mach-O writer that stops at the load commands produces
# something that can't run. It's also simple: a SuperBlob wrapping a
# CodeDirectory that holds a SHA-256 of every 4 KiB page of the file up to
# codeLimit. word already has SHA-256 in word, so it can sign its own output
# with no Apple tooling and no dependency, which keeps "no libc, no outside
# library" true on a platform that requires signing.
#
# Verified on Linux:
#   python3 dev/toolchain/macho_ref.py /tmp/w && llvm-objdump --macho --all-headers /tmp/w
# and against a real linker's output for the same structure:
#   lld -flavor darwin -arch arm64 -platform_version macos 11.0 11.0 -e _main -o ref m.o
import struct, hashlib, sys

BASE = 0x100000000
PAGE = 0x4000            # arm64 macOS pages are 16 KiB for segment alignment
SIGPAGE = 4096           # code-signature hash pages are always 4 KiB

def seg(name, vmaddr, vmsize, fileoff, filesize, maxprot, initprot, sects=b'', nsects=0):
    cmdsize = 72 + len(sects)
    return struct.pack('<II16sQQQQiiII', 0x19, cmdsize, name.encode(),
                       vmaddr, vmsize, fileoff, filesize,
                       maxprot, initprot, nsects, 0) + sects

def sect(sname, sgname, addr, size, offset, flags):
    return struct.pack('<16s16sQQIIIIIII4x', sname.encode(), sgname.encode(),
                       addr, size, offset, 4, 0, 0, flags, 0, 0)

def unixthread(pc):
    # ARM_THREAD_STATE64 = flavor 6, count 68 (34 x 64-bit: x0-x28, fp, lr, sp, pc, cpsr)
    # Only 'static' mode uses this. A dyld-less image carrying it is SIGKILLed
    # on Apple Silicon (so is Apple's own `ld -static` output), which is why
    # the default mode below is the dyld one.
    state = b'\0' * (29*8) + struct.pack('<QQQQ', 0, 0, 0, pc) + b'\0'*8
    assert len(state) == 272, len(state)
    return struct.pack('<IIII', 0x5, 16 + len(state), 6, 68) + state

def dylinker():
    # LC_LOAD_DYLINKER. dyld is the only thing this image loads, and it loads
    # nothing further: there is no LC_LOAD_DYLIB, so no libc, no dylib and no
    # foreign initialiser. dyld maps the image and jumps to the entry.
    name = b'/usr/lib/dyld\0'
    body = struct.pack('<I', 12) + name
    pad = -len(body) % 8
    return struct.pack('<II', 0xe, 8 + len(body) + pad) + body + b'\0' * pad

def main_cmd(entryoff):
    # LC_MAIN (0x28 | LC_REQ_DYLD). entryoff is a file offset, not an address,
    # because dyld adds the slide itself. That's the reason to use it.
    return struct.pack('<IIQQ', 0x80000028, 24, entryoff, 0)

def symtab(off):
    # An empty symbol table, in the shape a real linker leaves one. Nothing
    # here resolves anything; dyld has nothing to bind.
    return (struct.pack('<IIIIII', 0x2, 24, off, 0, off, 0)
            + struct.pack('<II', 0xb, 80) + struct.pack('<I', 0) * 18)

def build(text, rodata, data, bsslen, entry_off, ident, mode='dyld'):
    ncmds_bytes = [None]           # filled after we know the sizes
    # ---- lay the file out -------------------------------------------------
    # __TEXT holds the header and the load commands, so text starts after them.
    hdr = 32
    # sizes are known once we know how many commands; do a fixed layout
    # pagezero, text+1sect, rodata, data, linkedit, buildver, entry, codesig
    tail = {'static': 288, 'dyld': 32 + 24 + 24 + 80, 'dyld-nosym': 32 + 24}[mode]
    lc_len = 72 + (72 + 80) + 72 + 72 + 72 + 24 + tail + 16
    tstart = align(hdr + lc_len, PAGE)
    tlen   = len(text)
    rstart = align(tstart + tlen, PAGE); rlen = len(rodata)
    dstart = align(rstart + rlen, PAGE); dlen = len(data)
    # __DATA's vm extent covers bss, which has no file bytes, so __LINKEDIT
    # can't just follow it in the file and take the matching address. The file
    # offset and the vm address are computed separately, and __LINKEDIT starts
    # after the end of __DATA in memory.
    datavm = align(dlen + bsslen, PAGE) or PAGE
    lstart = align(dstart + dlen, PAGE)             # __LINKEDIT: the signature
    if lstart <= dstart:
        lstart = dstart + PAGE
    lvaddr = BASE + dstart + datavm
    entry  = BASE + tstart + entry_off

    codelimit = lstart
    npages = (codelimit + SIGPAGE - 1) // SIGPAGE
    idb = ident.encode() + b'\0'
    # A CodeDirectory's header length is fixed by its declared version, and
    # 0x20400 runs to execSegFlags: 88 bytes. Declaring 0x20400 over a shorter
    # header doesn't parse leniently. codesign reads the identifier out of the
    # middle of the header and decides the object isn't signed at all, and the
    # kernel SIGKILLs the process. llvm-objdump doesn't notice.
    CDHDR = 88
    cd_len = CDHDR + len(idb) + npages*32
    sig_len = 12 + 8 + cd_len
    sig_len_padded = align(sig_len, 16)

    cmds  = seg('__PAGEZERO', 0, BASE, 0, 0, 0, 0)
    cmds += seg('__TEXT', BASE, align(tstart+tlen, PAGE), 0, tstart+tlen, 5, 5,
                sect('__text', '__TEXT', BASE+tstart, tlen, tstart, 0x80000400), 1)
    cmds += seg('__RODATA', BASE+rstart, align(rlen, PAGE), rstart, rlen, 1, 1)
    cmds += seg('__DATA', BASE+dstart, datavm, dstart, dlen, 3, 3)
    cmds += seg('__LINKEDIT', lvaddr, align(sig_len_padded, PAGE), lstart, sig_len_padded, 1, 1)
    # LC_BUILD_VERSION: platform 1 is macOS, minos/sdk 11.0.0 packed as xxxx.yy.zz.
    # A modern kernel wants an image to say what it was built for.
    cmds += struct.pack('<IIIII', 0x32, 24, 1, 0x000b0000, 0x000b0000) + struct.pack('<I', 0)
    if mode == 'static':
        cmds += unixthread(entry)
        ncmds = 8
    else:
        cmds += dylinker() + main_cmd(tstart + entry_off)
        ncmds = 9
        if mode == 'dyld':
            cmds += symtab(lstart)
            ncmds = 11
    cmds += struct.pack('<IIII', 0x1d, 16, lstart, sig_len_padded)   # LC_CODE_SIGNATURE
    assert len(cmds) == lc_len, (len(cmds), lc_len)

    # MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_PIE for a dyld image. A
    # static one sets only MH_NOUNDEFS, since it isn't dynamically linked,
    # two-level or position-independent.
    flags = 0x00000001 if mode == 'static' else 0x00200085
    head = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000c, 0, 2, ncmds, len(cmds), flags, 0)
    out = bytearray(head + cmds)
    out += b'\0' * (tstart - len(out)); out += text
    out += b'\0' * (rstart - len(out)); out += rodata
    out += b'\0' * (dstart - len(out)); out += data
    out += b'\0' * (lstart - len(out))
    # ---- the ad-hoc signature over every 4 KiB page up to codeLimit -------
    hashes = b''.join(hashlib.sha256(bytes(out[i*SIGPAGE:(i+1)*SIGPAGE])).digest()
                      for i in range(npages))
    ioff = CDHDR
    hoff = ioff + len(idb)
    cd = struct.pack('>IIIIIIIIIBBBBI', 0xfade0c02, cd_len, 0x00020400,
                     0x00020002, hoff, ioff, 0, npages, codelimit, 32, 2, 0, 12, 0)
    cd += struct.pack('>III', 0, 0, 0)      # scatterOffset, teamOffset, spare3
    cd += struct.pack('>Q', 0)              # codeLimit64 (codeLimit fits in 32)
    # the executable segment: __TEXT, and the flag that says this is the main binary
    cd += struct.pack('>QQQ', 0, tstart + tlen, 1)
    cd += idb + hashes
    assert len(cd) == cd_len, (len(cd), cd_len)
    sb = struct.pack('>III', 0xfade0cc0, sig_len, 1) + struct.pack('>II', 0, 20) + cd
    out += sb + b'\0' * (sig_len_padded - len(sb))
    return bytes(out)

def align(n, a): return (n + a - 1) // a * a

if __name__ == '__main__':
    # mov w0, #42 ; mov x16, #1 (SYS_exit) ; svc #0x80
    text = struct.pack('<III', 0x52800540, 0xd2800030, 0xd4001001)
    # mode: 'dyld' (default), 'dyld-nosym' or 'static'. A dyld-less static
    # image doesn't run on Apple Silicon (Apple's own ld -static output is
    # SIGKILLed the same way), so 'static' is only there as the control that
    # shows it.
    mode = sys.argv[2] if len(sys.argv) > 2 else 'dyld'
    open(sys.argv[1], 'wb').write(build(text, b'\0'*16, b'\0'*16, 4096, 0, 'wtest', mode))
