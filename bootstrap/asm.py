#!/usr/bin/env python3
"""A from-scratch x86-64 encoder for the instruction subset bootstrap/codegen.py
emits. Intel syntax. Encoders return machine-code bytes; label references are
emitted as (kind, name) relocations resolved by the linker pass in asm_link.py.

It was checked against GNU as, and test_bootstrap_seed.sh checks it again
whenever GNU as/ld are on PATH: `python3 bootstrap/wordc.py compiler/word.w
--binutils` assembles the same text with GNU as/ld instead, and both routes have
to reach the same word_B."""

R64 = {n:i for i,n in enumerate(
    "rax rcx rdx rbx rsp rbp rsi rdi r8 r9 r10 r11 r12 r13 r14 r15".split())}
R32 = {n:i for i,n in enumerate(
    "eax ecx edx ebx esp ebp esi edi r8d r9d r10d r11d r12d r13d r14d r15d".split())}
R16 = {n:i for i,n in enumerate(
    "ax cx dx bx sp bp si di r8w r9w r10w r11w r12w r13w r14w r15w".split())}
R8  = {n:i for i,n in enumerate(
    "al cl dl bl spl bpl sil dil r8b r9b r10b r11b r12b r13b r14b r15b".split())}
REGSIZE = {}
for t,sz in ((R64,8),(R32,4),(R16,2),(R8,1)):
    for n in t: REGSIZE[n]=sz
def regnum(n):
    for t in (R64,R32,R16,R8):
        if n in t: return t[n]
    raise KeyError(n)

class Reloc:
    def __init__(self, kind, name, off, addend=0): self.kind, self.name, self.off, self.addend = kind, name, off, addend

def imm_bytes(v, n):
    v &= (1<<(8*n))-1
    return v.to_bytes(n, "little")

def sign8(v): return -128 <= v <= 127

def parse_mem(s):
    """[base+index*scale+disp] / [rip+label] -> dict."""
    inner = s[s.index("[")+1:s.rindex("]")].strip().replace(" ", "")
    m = {"base":None,"index":None,"scale":1,"disp":0,"rip":None}
    # split on + / - keeping signs for disp
    toks = inner.replace("-","+-").split("+")
    for t in toks:
        t=t.strip()
        if not t: continue
        if t=="rip": m["rip"]=True; continue
        if "*" in t:
            r,sc=t.split("*"); m["index"]=r.strip(); m["scale"]=int(sc); continue
        if t.lstrip("-").isdigit():
            m["disp"]+=int(t); continue
        if t in R64:
            if m["base"] is None: m["base"]=t
            else: m["index"]=t
            continue
        # a symbol used as displacement (rare) or rip label
        m["label"]=t.lstrip("-")
    return m

def parse_operand(s):
    s=s.strip()
    size=None
    for pfx,sz in (("byte ptr",1),("word ptr",2),("dword ptr",4),("qword ptr",8)):
        if s.startswith(pfx): size=sz; s=s[len(pfx):].strip(); break
    if s.startswith("["):
        mm=parse_mem(s); mm["size"]=size; return ("mem",mm)
    if s in REGSIZE: return ("reg",s)
    # immediate (number) or label (for call/jmp/lea targets handled separately)
    neg = s.startswith("-")
    body = s[1:] if neg else s
    if body.isdigit(): return ("imm", int(s))
    if body.lower().startswith("0x"): return ("imm", int(s,16))
    return ("label", s)

def rex(w,r,x,b,force=False):
    val=0x40|(w<<3)|(r<<2)|(x<<1)|b
    return bytes([val]) if (force or val!=0x40) else b""

def modrm(mod,reg,rm): return bytes([(mod<<6)|((reg&7)<<3)|(rm&7)])
def sib(scale,index,base):
    ss={1:0,2:1,4:2,8:3}[scale]
    return bytes([(ss<<6)|((index&7)<<3)|(base&7)])

def enc_mem_operand(reg_field, mem, out_reloc, cur_len_before_disp):
    """Return (rex_r_x_b tuple, bytes) for a memory operand with given reg field (reg number)."""
    m=mem; relocs=[]
    if m.get("rip"):
        # RIP-relative: modrm mod=00 rm=101, disp32 = reloc to label (+ any disp as addend)
        code = modrm(0,reg_field,5)
        rel = ("PC32", m.get("label"), m.get("disp",0))
        code += b"\x00\x00\x00\x00"
        return (0,0,0), code, rel
    base=m["base"]; index=m["index"]; scale=m["scale"]; disp=m["disp"]
    rexX = 1 if (index and regnum(index)>=8) else 0
    rexB = 1 if (base and regnum(base)>=8) else 0
    bn = regnum(base) if base else None
    need_sib = (index is not None) or (base in ("rsp","r12")) or (base is None)
    # choose disp size
    if base is None and index is not None:
        modb=0; dsz=4
    elif base is None:
        modb=0; dsz=4
    else:
        if disp==0 and (bn&7)!=5: modb=0; dsz=0
        elif sign8(disp): modb=1; dsz=1
        else: modb=2; dsz=4
    if need_sib:
        idx = regnum(index) if index else 4  # 4 = no index
        b_ = (bn&7) if base is not None else 5
        code = modrm(modb, reg_field, 4) + sib(scale, idx, b_)
    else:
        code = modrm(modb, reg_field, bn&7)
    if dsz: code += imm_bytes(disp, dsz)
    return (0, rexX, rexB), code, None

# ---- per-instruction encoders (return (bytes, relocs)) ----
ALU = {"add":(0x01,0),"or":(0x09,1),"adc":(0x11,2),"sbb":(0x19,3),"and":(0x21,4),
       "sub":(0x29,5),"xor":(0x31,6),"cmp":(0x39,7)}
JCC = {"jo":0x80,"jno":0x81,"jb":0x82,"jc":0x82,"jae":0x83,"jnc":0x83,"je":0x84,"jz":0x84,
       "jne":0x85,"jnz":0x85,"jbe":0x86,"ja":0x87,"js":0x88,"jns":0x89,"jl":0x8c,"jge":0x8d,
       "jle":0x8e,"jg":0x8f}
SETCC={"seto":0x90,"setb":0x92,"setc":0x92,"setae":0x93,"setnc":0x93,"sete":0x94,"setne":0x95,
       "seta":0x97,"sets":0x98,"setl":0x9c,"setge":0x9d,"setle":0x9e,"setg":0x9f}
SHIFT={"rol":0,"ror":1,"shl":4,"sal":4,"shr":5,"sar":7}

def split_ops(s):
    if not s: return []
    out=[]; depth=0; cur=""
    for c in s:
        if c=="[": depth+=1
        if c=="]": depth-=1
        if c=="," and depth==0: out.append(cur.strip()); cur=""
        else: cur+=c
    if cur.strip(): out.append(cur.strip()); return out

def w_of(reg): return 1 if REGSIZE[reg]==8 else 0

def rex_rm(w, regf, mem_or_reg, force=False):
    # returns rex byte for reg-field regf and an r/m operand
    if mem_or_reg[0]=="reg":
        rm=regnum(mem_or_reg[1]); return rex(w, 1 if regf>=8 else 0, 0, 1 if rm>=8 else 0, force)
    return None

def encode(mn, opstr):
    ops=[parse_operand(o) for o in split_ops(opstr)]
    relocs=[]
    def addrel(rel, trailing=0):
        # reloc = (kind, name, from_end, addend). from_end = bytes from the end of
        # the instruction back to the START of the 4-byte disp32 field (= 4 + any
        # trailing immediate). For a RIP-relative operand the disp is measured from
        # the end of the WHOLE instruction, so the trailing bytes must be folded into
        # the addend: addend = label_disp - trailing.
        if rel: relocs.append((rel[0], rel[1], 4+trailing, (rel[2] if len(rel)>2 else 0) - trailing))
    def mem_enc(regf, mem):
        (_,rx,rb),code,rel = enc_mem_operand(regf&7, mem, relocs, 0)
        return rx, rb, code, rel
    # no-operand
    if mn=="syscall": return b"\x0f\x05",[]
    if mn=="ret": return b"\xc3",[]
    if mn=="leave": return b"\xc9",[]
    if mn=="cld": return b"\xfc",[]
    if mn=="clc": return b"\xf8",[]
    if mn=="cqo": return b"\x48\x99",[]
    if mn=="nop": return b"\x90",[]
    if mn=="rep": return None,None  # handled by caller with the next mnemonic
    if mn in ("movsb","stosb","movsq","stosq"):
        base={"movsb":b"\xa4","stosb":b"\xaa","movsq":b"\x48\xa5","stosq":b"\x48\xab"}[mn]
        return base,[]
    # push/pop reg
    if mn in ("push","pop") and ops and ops[0][0]=="reg":
        r=regnum(ops[0][1]); pre=rex(0,0,0,1 if r>=8 else 0); op=(0x50 if mn=="push" else 0x58)+(r&7)
        return pre+bytes([op]),[]
    # call/jmp label or reg
    if mn in ("call","jmp"):
        o=ops[0]
        if o[0] in ("label","imm"):
            op=0xe8 if mn=="call" else 0xe9
            relocs.append(("PC32",o[1] if o[0]=="label" else None,4,0))
            return bytes([op])+b"\x00\x00\x00\x00", relocs
        if o[0]=="reg":
            r=regnum(o[1]); pre=rex(0,0,0,1 if r>=8 else 0)
            return pre+bytes([0xff])+modrm(3,(2 if mn=="call" else 4),r&7),[]
    if mn in JCC:
        relocs.append(("PC32",ops[0][1],4,0))
        return bytes([0x0f,JCC[mn]])+b"\x00\x00\x00\x00", relocs
    if mn in SETCC:
        o=ops[0]
        if o[0]=="reg":
            r=regnum(o[1]); pre=rex(0,0,0,1 if r>=8 else 0, force=(o[1] in ("spl","bpl","sil","dil")))
            return pre+bytes([0x0f,SETCC[mn]])+modrm(3,0,r&7),[]
        rx,rb,code,rel=mem_enc(0,o[1]); 
        addrel(rel)
        return rex(0,0,rx,rb)+bytes([0x0f,SETCC[mn]])+code, relocs
    # movabs reg, imm64
    if mn=="movabs":
        r=regnum(ops[0][1]); pre=rex(1,0,0,1 if r>=8 else 0)
        return pre+bytes([0xb8+(r&7)])+imm_bytes(ops[1][1],8),[]
    if mn=="bswap":
        r=regnum(ops[0][1]); w=w_of(ops[0][1])
        return rex(w,0,0,1 if r>=8 else 0)+bytes([0x0f,0xc8+(r&7)]),[]
    # movzx / movsx
    if mn in ("movzx","movsx"):
        dst=ops[0]; src=ops[1]; dr=regnum(dst[1]); w=w_of(dst[1])
        op2 = {"movzx":0xb6,"movsx":0xbe}[mn]
        if src[0]=="reg":
            srcsz=REGSIZE[src[1]]; op2 += (1 if srcsz==2 else 0); sr=regnum(src[1])
            pre=rex(w,1 if dr>=8 else 0,0,1 if sr>=8 else 0, force=(src[1] in ("spl","bpl","sil","dil")))
            return pre+bytes([0x0f,op2])+modrm(3,dr,sr&7),[]
        else:
            msz=src[1].get("size") or 1; op2 += (1 if msz==2 else 0)
            rx,rb,code,rel=mem_enc(dr,src[1])
            addrel(rel)
            return rex(w,1 if dr>=8 else 0,rx,rb)+bytes([0x0f,op2])+code, relocs
    # inc/dec/neg/not/mul/div/idiv (0xff /0/1, 0xf7 /2/3/4/6/7)
    UN={"inc":(0xff,0),"dec":(0xff,1),"not":(0xf7,2),"neg":(0xf7,3),"mul":(0xf7,4),
        "imul1":(0xf7,5),"div":(0xf7,6),"idiv":(0xf7,7)}
    if mn in ("inc","dec","not","neg","div","idiv","mul") or (mn=="imul" and len(ops)==1):
        key=mn if mn!="imul" else "imul1"; op,dig=UN[key]; o=ops[0]
        if o[0]=="reg":
            r=regnum(o[1]); sz=REGSIZE[o[1]]
            if sz==1:  # r/m8 form: opcode-1, no REX.W
                return rex(0,0,0,1 if r>=8 else 0, force=(o[1] in ("spl","bpl","sil","dil")))+bytes([op-1])+modrm(3,dig,r&7),[]
            pre=b"\x66" if sz==2 else b""
            return pre+rex(1 if sz==8 else 0,0,0,1 if r>=8 else 0)+bytes([op])+modrm(3,dig,r&7),[]
        sz=o[1].get("size") or 8
        rx,rb,code,rel=mem_enc(dig,o[1])
        addrel(rel)
        if sz==1: return rex(0,0,rx,rb)+bytes([op-1])+code, relocs   # byte ptr: opcode-1
        pre=b"\x66" if sz==2 else b""
        return pre+rex(1 if sz==8 else 0,0,rx,rb)+bytes([op])+code, relocs
    # imul reg, reg, imm  (0x6b imm8 / 0x69 imm32)
    if mn=="imul" and len(ops)==3:
        dr=regnum(ops[0][1]); sr=regnum(ops[1][1]); w=w_of(ops[0][1]); imm=ops[2][1]
        pre=rex(w,1 if dr>=8 else 0,0,1 if sr>=8 else 0)
        if sign8(imm): return pre+bytes([0x6b])+modrm(3,dr,sr&7)+imm_bytes(imm,1),[]
        return pre+bytes([0x69])+modrm(3,dr,sr&7)+imm_bytes(imm,4),[]
    # imul reg, reg/mem  (0f af)
    if mn=="imul" and len(ops)==2:
        dr=regnum(ops[0][1]); w=w_of(ops[0][1])
        if ops[1][0]=="reg":
            sr=regnum(ops[1][1])
            return rex(w,1 if dr>=8 else 0,0,1 if sr>=8 else 0)+bytes([0x0f,0xaf])+modrm(3,dr,sr&7),[]
        rx,rb,code,rel=mem_enc(dr,ops[1][1]); addrel(rel)
        return rex(w,1 if dr>=8 else 0,rx,rb)+bytes([0x0f,0xaf])+code, relocs
    # shifts
    if mn in SHIFT:
        dig=SHIFT[mn]; dst=ops[0]; src=ops[1]; r=regnum(dst[1]); w=w_of(dst[1])
        if src[0]=="reg" and src[1]=="cl":
            return rex(w,0,0,1 if r>=8 else 0)+bytes([0xd3])+modrm(3,dig,r&7),[]
        if src[0]=="imm" and src[1]==1:
            return rex(w,0,0,1 if r>=8 else 0)+bytes([0xd1])+modrm(3,dig,r&7),[]
        return rex(w,0,0,1 if r>=8 else 0)+bytes([0xc1])+modrm(3,dig,r&7)+imm_bytes(src[1],1),[]
    # lea
    if mn=="lea":
        dr=regnum(ops[0][1]); w=w_of(ops[0][1]); rx,rb,code,rel=mem_enc(dr,ops[1][1])
        addrel(rel)
        return rex(w,1 if dr>=8 else 0,rx,rb)+bytes([0x8d])+code, relocs
    # test
    if mn=="test":
        a,b=ops
        if a[0]=="reg" and b[0]=="reg":
            dr=regnum(a[1]); sr=regnum(b[1]); w=w_of(a[1])
            if REGSIZE[a[1]]==1:
                pre=rex(0,1 if sr>=8 else 0,0,1 if dr>=8 else 0, force=(a[1] in ("spl","bpl","sil","dil") or b[1] in ("spl","bpl","sil","dil")))
                return pre+bytes([0x84])+modrm(3,sr,dr&7),[]
            return rex(w,1 if sr>=8 else 0,0,1 if dr>=8 else 0)+bytes([0x85])+modrm(3,sr,dr&7),[]
        if a[0]=="reg" and b[0]=="imm":
            r=regnum(a[1]); w=w_of(a[1]); sz=REGSIZE[a[1]]
            if sz==1:
                if a[1]=="al": return bytes([0xa8])+imm_bytes(b[1],1),[]
                return rex(0,0,0,1 if r>=8 else 0,force=(a[1] in ("spl","bpl","sil","dil")))+bytes([0xf6])+modrm(3,0,r&7)+imm_bytes(b[1],1),[]
            if a[1] in ("rax","eax"): return rex(w,0,0,0)+bytes([0xa9])+imm_bytes(b[1],4),[]
            return rex(w,0,0,1 if r>=8 else 0)+bytes([0xf7])+modrm(3,0,r&7)+imm_bytes(b[1],4),[]
    # mov
    if mn=="mov":
        a,b=ops
        if a[0]=="reg" and b[0]=="reg":
            dr=regnum(a[1]); sr=regnum(b[1]); w=w_of(a[1])
            return rex(w,1 if sr>=8 else 0,0,1 if dr>=8 else 0)+bytes([0x88 if w==0 and REGSIZE[a[1]]==1 else 0x89])+modrm(3,sr,dr&7),[]
        if a[0]=="reg" and b[0]=="imm":
            r=regnum(a[1]); w=w_of(a[1])
            if REGSIZE[a[1]]==1:  # mov r8, imm8 = B0+r ib
                pre=rex(0,0,0,1 if r>=8 else 0, force=(a[1] in ("spl","bpl","sil","dil")))
                return pre+bytes([0xb0+(r&7)])+imm_bytes(b[1],1),[]
            return rex(w,0,0,1 if r>=8 else 0)+bytes([0xc7])+modrm(3,0,r&7)+imm_bytes(b[1],4),[]
        if a[0]=="reg" and b[0]=="mem":
            dr=regnum(a[1]); w=w_of(a[1]); rx,rb,code,rel=mem_enc(dr,b[1])
            addrel(rel)
            op=0x8a if REGSIZE[a[1]]==1 else 0x8b
            return rex(w,1 if dr>=8 else 0,rx,rb)+bytes([op])+code, relocs
        if a[0]=="mem" and b[0]=="reg":
            sr=regnum(b[1]); w=w_of(b[1]); rx,rb,code,rel=mem_enc(sr,a[1])
            addrel(rel)
            op=0x88 if REGSIZE[b[1]]==1 else 0x89
            return rex(w,1 if sr>=8 else 0,rx,rb)+bytes([op])+code, relocs
        if a[0]=="mem" and b[0]=="imm":
            sz=a[1].get("size") or 8; rx,rb,code,rel=mem_enc(0,a[1])
            addrel(rel, {1:1,2:2}.get(sz,4))
            if sz==1: return rex(0,0,rx,rb)+bytes([0xc6])+code+imm_bytes(b[1],1), relocs
            if sz==2: return b"\x66"+rex(0,0,rx,rb)+bytes([0xc7])+code+imm_bytes(b[1],2), relocs
            return rex(1 if sz==8 else 0,0,rx,rb)+bytes([0xc7])+code+imm_bytes(b[1],4), relocs
    # ALU family
    if mn in ALU:
        opc,dig=ALU[mn]; a,b=ops
        def bforce(*rs): return any(r in ("spl","bpl","sil","dil") for r in rs)
        if a[0]=="reg" and b[0]=="reg":
            dr=regnum(a[1]); sr=regnum(b[1]); w=w_of(a[1])
            if REGSIZE[a[1]]==1:  # 8-bit store form: opcode-1
                return rex(0,1 if sr>=8 else 0,0,1 if dr>=8 else 0, force=bforce(a[1],b[1]))+bytes([opc-1])+modrm(3,sr,dr&7),[]
            return rex(w,1 if sr>=8 else 0,0,1 if dr>=8 else 0)+bytes([opc])+modrm(3,sr,dr&7),[]
        if a[0]=="reg" and b[0]=="imm":
            r=regnum(a[1]); w=w_of(a[1]); sz=REGSIZE[a[1]]
            if sz==1:
                if a[1]=="al": return bytes([opc+3])+imm_bytes(b[1],1),[]
                return rex(0,0,0,1 if r>=8 else 0, force=(a[1] in ("spl","bpl","sil","dil")))+bytes([0x80])+modrm(3,dig,r&7)+imm_bytes(b[1],1),[]
            if sign8(b[1]): return rex(w,0,0,1 if r>=8 else 0)+bytes([0x83])+modrm(3,dig,r&7)+imm_bytes(b[1],1),[]
            if a[1] in ("rax","eax"): return rex(w,0,0,0)+bytes([opc+4])+imm_bytes(b[1],4),[]
            return rex(w,0,0,1 if r>=8 else 0)+bytes([0x81])+modrm(3,dig,r&7)+imm_bytes(b[1],4),[]
        if a[0]=="reg" and b[0]=="mem":
            dr=regnum(a[1]); w=w_of(a[1]); rx,rb,code,rel=mem_enc(dr,b[1])
            addrel(rel)
            opcode=(opc+1) if REGSIZE[a[1]]==1 else (opc+2)  # 8-bit load form: (opc+2)-1
            return rex(w,1 if dr>=8 else 0,rx,rb, force=(REGSIZE[a[1]]==1 and bforce(a[1])))+bytes([opcode])+code, relocs
        if a[0]=="mem" and b[0]=="reg":
            sr=regnum(b[1]); w=w_of(b[1]); rx,rb,code,rel=mem_enc(sr,a[1])
            addrel(rel)
            opcode=(opc-1) if REGSIZE[b[1]]==1 else opc  # 8-bit store form
            return rex(w,1 if sr>=8 else 0,rx,rb, force=(REGSIZE[b[1]]==1 and bforce(b[1])))+bytes([opcode])+code, relocs
        if a[0]=="mem" and b[0]=="imm":
            sz=a[1].get("size") or 8; rx,rb,code,rel=mem_enc(dig,a[1])
            addrel(rel, 1 if (sz==1 or sign8(b[1])) else 4)
            if sz==1: return rex(0,0,rx,rb)+bytes([0x80])+code+imm_bytes(b[1],1), relocs
            if sign8(b[1]): return rex(1,0,rx,rb)+bytes([0x83])+code+imm_bytes(b[1],1), relocs
            return rex(1,0,rx,rb)+bytes([0x81])+code+imm_bytes(b[1],4), relocs
    raise NotImplementedError(f"{mn} {opstr}")
