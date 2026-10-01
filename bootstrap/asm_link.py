#!/usr/bin/env python3
"""Two-pass assembler and static ELF64 writer. Parses the Intel-syntax .s that
bootstrap/codegen.py emits, lays out .text/.rodata/.data/.bss, resolves PC32
relocations, and writes a runnable static executable. No external as/ld.

Multiple inputs are merged the way `ld` merges same-named sections, and
cross-file references resolve through one shared symbol table. Nothing in the
tree needs that now, since word's own TLS stack is word source compiled with the
program.

A duplicate label is an error. Keeping one definition would make every reference
to the other run the wrong code, and that shows up as a logic error in the
compiled program, far from the assembler."""
import sys, struct, re, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asm import encode

def unescape(s):
    out=bytearray(); i=0
    while i<len(s):
        c=s[i]
        if c=="\\":
            n=s[i+1]; out.append({'n':10,'t':9,'r':13,'0':0,'\\':92,'"':34,"'":39}[n]); i+=2
        else: out.append(ord(c)); i+=1
    return bytes(out)

def collect_equs(texts):
    """Pre-pass: gather every .equ NAME, INT so the values can be substituted into
    instruction operands (e.g. `mov rcx, rsa_oid_len`) before encoding."""
    equs={}
    for text in texts:
        for raw in text.splitlines():
            m=re.match(r'^\s*\.equ\s+([.\w]+)\s*,\s*(.+?)\s*(#.*)?$', raw)
            if m:
                try: equs[m.group(1)]=int(m.group(2).strip(),0)
                except ValueError: pass
    return equs

def subst_equs(operands, equs):
    """Replace whole-token .equ names with their integer value. Registers, labels,
    and numbers are left untouched (they are never .equ keys)."""
    if not equs: return operands
    return re.sub(r'[.\w]+',
                  lambda mo: str(equs[mo.group(0)]) if mo.group(0) in equs else mo.group(0),
                  operands)

def assemble(texts):
    """Assemble one or more intel-syntax sources into merged sections. `texts` is a
    list of source strings, concatenated in order like separate object files fed to
    the linker. Returns (secs, labels, relocs, bss_size, entry)."""
    secs={".text":bytearray(),".rodata":bytearray(),".data":bytearray(),".bss":bytearray()}
    labels={}; relocs=[]; bss_size=0; entry=None
    equs=collect_equs(texts)
    for text in texts:
        cur=".text"  # each file starts in .text, as `as` assumes
        for raw in text.splitlines():
            line=raw.split("#",1)[0].rstrip()
            if not line.strip(): continue
            s=line.strip()
            # leading label(s): "name:" optionally followed by an instruction
            while True:
                m=re.match(r'^([.\w]+):\s*(.*)$', s)
                if not m: break
                # A duplicate is an error: whichever definition won, the
                # references meant for the other would run the wrong code. That
                # happened once, with fn_pin_scan_body defined by both `pin_scan`
                # and `pin_scan_body`.
                if m.group(1) in labels:
                    raise ValueError(f"duplicate label: {m.group(1)}")
                labels[m.group(1)]=(cur, bss_size if cur==".bss" else len(secs[cur]))
                s=m.group(2).strip()
                if not s: break
            if not s: continue
            if s.startswith("."):
                d=s.split(None,1); name=d[0]; arg=d[1] if len(d)>1 else ""
                if name==".intel_syntax": continue
                if name==".global": entry=entry or arg.strip(); continue
                if name==".text": cur=".text"; continue
                if name==".section":
                    sec=arg.split(",")[0].strip()
                    if sec not in secs: secs[sec]=bytearray()
                    cur=".bss" if sec==".bss" else (sec if sec in (".rodata",".data") else ".rodata")
                    continue
                if name==".align":
                    n=int(arg,0)
                    if cur==".bss":
                        while bss_size%n: bss_size+=1
                    else:
                        while len(secs[cur])%n: secs[cur].append(0)
                    continue
                if name==".equ": continue  # already gathered in the pre-pass
                if name in (".quad",".long",".short",".byte"):
                    sz={".quad":8,".long":4,".short":2,".byte":1}[name]
                    for part in arg.split(","):
                        p=part.strip()
                        v=equs.get(p)
                        if v is None: v=int(p,0)
                        secs[cur]+=(v & ((1<<(8*sz))-1)).to_bytes(sz,"little")
                    continue
                if name in (".ascii",".asciz",".string"):
                    secs[cur]+=unescape(arg.strip().strip('"'))
                    if name!=".ascii": secs[cur]+=b"\x00"  # .asciz/.string append a NUL
                    continue
                if name in (".space",".zero"):
                    n=int(arg.split(",")[0],0)
                    if cur==".bss": bss_size+=n
                    else: secs[cur]+=b"\x00"*n
                    continue
                # Benign metadata `as` emits but that produces no bytes; safe to skip.
                if name in (".file",".type",".size",".ident",".weak") or name.startswith(".cfi"):
                    continue
                # Any other directive is an error, so no bytes get dropped
                # unnoticed (a dropped .asciz once looked like broken decryption).
                raise NotImplementedError(f"unhandled directive: {name} {arg}")
            # instruction
            parts=s.split(None,1); mn=parts[0]; rest=subst_equs(parts[1] if len(parts)>1 else "", equs)
            if mn=="rep":
                p2=rest.split(None,1); code,r=encode(p2[0], p2[1] if len(p2)>1 else "")
                code=b"\xf3"+code
            else:
                code,r=encode(mn,rest)
            off=len(secs[".text"])
            for kind,rname,from_end,addend in r:
                # PC32 field starts `from_end` bytes before the end of the instruction
                relocs.append((kind, rname, off+len(code)-from_end, addend))
            secs[".text"]+=code
    return secs, labels, relocs, bss_size, (entry or "_start")

def align_up(n, a): return (n + a - 1) & ~(a - 1)

def link_elf(secs, labels, relocs, bss_size, entry, base=0x400000):
    ehsize=64; phsize=56; nph=1
    file_off=ehsize+phsize*nph
    # layout: .text, .rodata, .data in the file image; .bss follows in memory only.
    # 16-align each section base so in-section `.align` directives stay meaningful.
    order=[".text",".rodata",".data"]
    addr={}; blob=bytearray(); vaddr=base+file_off
    for sc in order:
        while (vaddr - base) % 16: blob.append(0); vaddr+=1
        addr[sc]=vaddr; blob+=secs[sc]; vaddr+=len(secs[sc])
    while (vaddr-base)%16: vaddr+=1   # bss base (memory only)
    bss_vaddr=vaddr
    def sym_vaddr(name):
        if name not in labels: raise KeyError(f"undefined symbol: {name}")
        sc,o=labels[name]
        return (bss_vaddr+o) if sc==".bss" else (addr[sc]+o)
    text_base=addr[".text"]
    for kind,name,off,addend in relocs:
        target=sym_vaddr(name); site=text_base+off  # reloc field is in .text
        rel=(target+addend)-(site+4)   # PC32: disp from end of the 4-byte field
        blob_off=site-(base+file_off)  # .text may sit past leading alignment padding
        blob[blob_off:blob_off+4]=struct.pack("<i", rel)
    entry_v=sym_vaddr(entry)
    memsz=len(blob)+bss_size
    e=bytearray()
    e+=b"\x7fELF"+bytes([2,1,1,0])+b"\x00"*8
    e+=struct.pack("<HHIQQQIHHHHHH",2,0x3e,1,entry_v,ehsize,0,0,ehsize,phsize,nph,0,0,0)
    ph=struct.pack("<IIQQQQQQ",1,7,0,base,base,len(blob)+file_off,memsz+file_off,0x1000)
    return bytes(e)+ph+bytes(blob)

if __name__=="__main__":
    if len(sys.argv)<3:
        sys.exit("usage: asm_link.py <in.s> [more.s ...] <out>")
    *ins, outp = sys.argv[1:]
    texts=[open(p).read() for p in ins]
    secs,labels,relocs,bss,entry=assemble(texts)
    out=link_elf(secs,labels,relocs,bss,entry)
    open(outp,"wb").write(out); os.chmod(outp,0o755)
    # the summary goes to stderr, so stdout stays clean in a pipeline
    print(f"wrote {outp}: .text={len(secs['.text'])} .rodata={len(secs['.rodata'])} "
          f".data={len(secs['.data'])} .bss={bss} relocs={len(relocs)} entry={entry}",
          file=sys.stderr)
