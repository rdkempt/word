#!/usr/bin/env python3
"""
Code generator for the bootstrap seed, phase 4 of bootstrap/wordc.py.

Walks the validated AST and emits x86-64 assembly (GNU as, Intel syntax) that
asm_link.py turns into a static ELF depending on nothing: I/O and memory come
straight from syscalls, with no libc (SPEC 14).

The only program this has to compile correctly is compiler/word.w, which allows
some simplifications the shipped compiler doesn't make. They're listed here so
an auditor comparing the two knows which differences are intended:

- **Values are untagged 64-bit words, and kind is decided by address.** Region
  space is one reserved range (mmap'd MAP_FIXED at REGION_BASE), so is_region(w)
  is a subtract and one unsigned compare, and an integer is just an integer. The
  shipped compiler tags values instead (2v+1; docs/VALUE_MODEL.md), which is
  faster and lets a region live anywhere. The seed needs neither. Both models
  guarantee that no integer can be mistaken for a region.
- **One region representation.** array(n), text(n) and bytes(n) all allocate the
  same word-per-element region. The shipped compiler tells them apart so `out`
  can render an array as [...] and a byte region can cost one byte per element.
  The seed has no JSON rendering, and every writer here already takes the low
  byte of each element, so a byte region would behave the same, using 8x the
  memory. kind() answers "text" where the shipped compiler answers "bytes", and
  word.w never asks.
- **A map is a linear scan.** The map box is three words, [2, pairs, self]: its
  second element points at the box itself, a shape no ordinary region has, so
  copy() can tell the two apart. word.w's own maps are small and few.
- **No optimiser.** Codegen is a stack machine: every expression leaves its result
  in rax and uses the stack for temporaries, so only rax carries a value across a
  runtime call. Registers r10/r11 are reserved for the runtime; rbx/r12-r15 are
  saved by any runtime routine that touches them. There's no register pinning,
  no bounds-check elision and no dead-store rewind. So word_A is slower than the
  binary it builds, and the binary it builds is byte-identical to the committed
  one, because the output depends on the source and not on what compiled the
  compiler.

Every runtime fault prints `word: <what> at line <n>` and exits 70, as SPEC 10.2
says.

Known limits, none of which compiler/word.w runs into: input integers wider
than 18 digits come back as text; an HTTP response body above 1 MiB is
truncated; cross-file semantic errors report the line but name the entry file;
and identical string literals aren't deduplicated.

Run it to print the assembly for the built-in sample:
    python3 codegen.py
Emit assembly for a file:
    python3 codegen.py path/to/app.w
"""

import sys
from lexer import Lexer, LexError
from parser import (Parser, ParseError, Program, Function, Hook, MapLit,
                    Decl, Assign, If, Loop, Return, Break, ExprStmt,
                    Num, Str, Name, Singleton, Binary, Unary, Index, Call)
from analyzer import Analyzer, AnalysisError, static_kind, NUMBER, REGION, UNKNOWN

REGION_BASE = 0x600000000000
REGION_SPAN = 0x80000000             # 2 GiB of address space, lazily committed
REGION_END = REGION_BASE + REGION_SPAN

SUPPORTED_BUILTINS = {"out", "len", "array"}
DEFERRED_BUILTINS = set()


class CodegenError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{line}:{col}: {msg}")
        self.line, self.col = line, col


ERR = {
    "prefix": "word: ",
    "div": "divide by zero",
    "bounds": "index out of bounds",
    "oom": "out of memory",
    "shift": "shift out of range",
    "wrlit": "write to a literal",
    "ordcmp": "cannot order-compare a number and text",
    "char": "not a character",
    "map": "could not map region space",
    "overflow": "overflow in division",
    "num": "number expected",
    "region": "region expected",
    "contract": "contract violation",
}


def _gas_ascii(label, s):
    """Emit a `.ascii` directive, escaping CR/LF/tab/quote/backslash so no raw
    control byte ever lands in the assembly (which GAS would reject)."""
    bs = chr(92)
    out = []
    for ch in s:
        o = ord(ch)
        if o == 10:
            out.append(bs + "n")
        elif o == 13:
            out.append(bs + "r")
        elif o == 9:
            out.append(bs + "t")
        elif ch == chr(34):
            out.append(bs + chr(34))
        elif ch == bs:
            out.append(bs + bs)
        else:
            out.append(ch)
    return label + ": .ascii " + chr(34) + "".join(out) + chr(34)


# The hand-written runtime. {BASE}/{SPAN}/{END} are filled in below.
RUNTIME = r"""
# ===== runtime =====
rt_init:
    mov qword ptr [rip+out_fd], 1    # out() -> stdout; err() swaps it to 2
    lea rax, [rsp+16]                 # argv[0] address (retaddr@rsp, argc@rsp+8)
    mov [rip+argv_ptr], rax
    mov rax, [rsp+8]
    mov [rip+argc_val], rax
    mov rax, [rip+argv_ptr]
    mov rcx, [rip+argc_val]
    lea rax, [rax + rcx*8 + 8]
    mov [rip+envp_ptr], rax
    mov rax, 9                       # mmap
    movabs rdi, {BASE}
    movabs rsi, {SPAN}
    mov rdx, 3                       # PROT_READ | PROT_WRITE
    mov r10, 0x32                    # MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED
    mov r8, -1
    xor r9, r9
    syscall
    movabs r11, {BASE}               # verify the fixed mapping landed where asked
    cmp rax, r11
    jne rt_mapfail
    movabs rdi, {BASE}               # copy literal pool to base of region space
    lea rsi, [rip+litpool]
    lea rcx, [rip+litpool_end]
    lea rax, [rip+litpool]
    sub rcx, rax                     # rcx = pool size in bytes
    cld
    rep movsb
    movabs rax, {BASE}
    lea rcx, [rip+litpool_end]
    lea rdx, [rip+litpool]
    sub rcx, rdx
    add rax, rcx                     # arena base = REGION_BASE + pool size
    mov [rip+arena_ptr], rax
    mov [rip+litpool_top], rax       # everything below here is a read-only literal
    ret

# rt_arg: rdi = n -> rax = region holding argv[n] as bytes (empty region if absent)
rt_arg:
    mov rax, [rip+argc_val]
    cmp rdi, rax
    jge .rta_empty
    cmp rdi, 0
    jl .rta_empty
    mov rax, [rip+argv_ptr]
    mov rsi, [rax + rdi*8]
    xor rdx, rdx
.rta_len:
    cmp byte ptr [rsi+rdx], 0
    je .rta_done
    inc rdx
    jmp .rta_len
.rta_done:
    push rsi
    push rdx
    lea rax, [rdx+1]
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    pop rdx
    pop rsi
    mov [rax], rdx
    xor rcx, rcx
.rta_cp:
    cmp rcx, rdx
    jge .rta_cpd
    movzx r8, byte ptr [rsi+rcx]
    mov [rax + rcx*8 + 8], r8
    inc rcx
    jmp .rta_cp
.rta_cpd:
    ret
.rta_empty:
    mov rdi, 8
    call rt_alloc
    mov qword ptr [rax], 0
    ret

# is_region: rdi -> rax in {0,1}; preserves all else
rt_isreg:
    push r11
    mov rax, rdi
    movabs r11, {BASE}
    sub rax, r11
    movabs r11, {SPAN}
    cmp rax, r11
    setb al
    movzx rax, al
    pop r11
    ret

# alloc: rdi = bytes -> rax = ptr; bumps arena, faults on exhaustion
rt_alloc:
    mov rax, [rip+arena_ptr]
    mov r10, rax
    add r10, rdi
    movabs r11, {END}
    cmp r10, r11
    ja rt_oom
    mov [rip+arena_ptr], r10
    ret

# rt_newreg: rdi = element count -> rax = a region of that many zero-filled
# elements. The arena is reused across mark()/reset(), so new storage isn't
# always fresh memory. array(n), text(n) and bytes(n) promise zeros (SPEC 9),
# so they write the zeros themselves.
rt_newreg:
    push rbx
    cmp rdi, 0
    jl rt_bounds
    mov rbx, rdi
    inc rdi
    shl rdi, 3
    call rt_alloc
    mov [rax], rbx
    xor rdx, rdx
    xor rcx, rcx
.nr_zero:
    cmp rcx, rbx
    jge .nr_done
    mov [rax + rcx*8 + 8], rdx
    inc rcx
    jmp .nr_zero
.nr_done:
    pop rbx
    ret

# rt_reset: rdi = a mark from mark() -> rewind the arena to it, unless the emit
# buffer sits at or above that mark. rt_asmput allocates and doubles the buffer
# in this same arena, and word.w marks around every function it emits, so
# rewinding past a buffer that grew inside the window would hand every byte
# already emitted to the next allocation. The buffer doubles only a handful of
# times in a whole compile, so the memory a skipped rewind keeps is small.
rt_reset:
    mov r10, [rip+emit_ptr]
    test r10, r10
    jz .rs_do
    cmp r10, rdi
    jae .rs_skip
.rs_do:
    mov [rip+arena_ptr], rdi
.rs_skip:
    ret

# num -> region of decimal digit code points; rdi = n -> rax = region
rt_num_to_region:
    push rbx
    push r12
    push r13
    push r14
    xor r13, r13
    mov rax, rdi
    cmp rax, 0
    jge .n2r_pos
    mov r13, 1
    neg rax
.n2r_pos:
    lea rbx, [rip+numscratch]
    xor r14, r14
    mov rcx, 10
.n2r_loop:
    xor rdx, rdx
    div rcx
    add dl, 48
    mov [rbx + r14], dl
    inc r14
    test rax, rax
    jnz .n2r_loop
    mov r12, r14
    add r12, r13
    mov rax, r12
    inc rax
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    mov [rax], r12
    mov r9, rax
    xor rcx, rcx
    test r13, r13
    jz .n2r_nosign
    mov qword ptr [r9+8], 45
    mov rcx, 1
.n2r_nosign:
    mov rdx, r14
.n2r_copy:
    test rdx, rdx
    jz .n2r_done
    dec rdx
    movzx rax, byte ptr [rbx+rdx]
    mov [r9 + rcx*8 + 8], rax
    inc rcx
    jmp .n2r_copy
.n2r_done:
    mov rax, r9
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# coerce to a region: rdi -> rax (region as-is, or number rendered)
rt_as_region:
    call rt_isreg
    test rax, rax
    jnz .asr_keep
    call rt_num_to_region
    ret
.asr_keep:
    mov rax, rdi
    ret

# join: rdi = a, rsi = b -> rax = new region (numbers rendered to text)
rt_join:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    call rt_as_region
    mov r12, rax
    mov rdi, r13
    call rt_as_region
    mov r13, rax
    mov r14, [r12]
    mov r15, [r13]
    mov rax, r14
    add rax, r15
    inc rax
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    mov rbx, rax
    mov rcx, r14
    add rcx, r15
    mov [rbx], rcx
    xor rcx, rcx
.join_a:
    cmp rcx, r14
    jge .join_b
    mov rax, [r12 + rcx*8 + 8]
    mov [rbx + rcx*8 + 8], rax
    inc rcx
    jmp .join_a
.join_b:
    xor rdx, rdx
.join_bl:
    cmp rdx, r15
    jge .join_done
    mov rax, [r13 + rdx*8 + 8]
    mov rcx, r14
    add rcx, rdx
    mov [rbx + rcx*8 + 8], rax
    inc rdx
    jmp .join_bl
.join_done:
    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---- sys, args, env, random, dir --------------------------------------------
#
# rt_cstr_region: rsi = char* -> rax = region of its bytes, one per element.
rt_cstr_region:
    push rbx
    push r12
    mov r12, rsi
    xor rdx, rdx
.cs_len:
    cmp byte ptr [r12+rdx], 0
    je .cs_have
    inc rdx
    jmp .cs_len
.cs_have:
    push rdx
    lea rax, [rdx+1]
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    pop rdx
    mov [rax], rdx
    mov rbx, rax
    xor rcx, rcx
.cs_cp:
    cmp rcx, rdx
    jge .cs_done
    movzx r8, byte ptr [r12+rcx]
    mov [rbx + rcx*8 + 8], r8
    inc rcx
    jmp .cs_cp
.cs_done:
    mov rax, rbx
    pop r12
    pop rbx
    ret

# rt_args: -> rax = a region of regions, argv[0] first.
rt_args:
    push rbx
    push r12
    push r13
    mov r13, [rip+argc_val]
    mov rdi, r13
    inc rdi
    shl rdi, 3
    call rt_alloc
    mov [rax], r13
    mov rbx, rax
    xor r12, r12
.ra_loop:
    cmp r12, r13
    jge .ra_done
    mov rdi, r12
    call rt_arg
    mov [rbx + r12*8 + 8], rax
    inc r12
    jmp .ra_loop
.ra_done:
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

# rt_env: rdi = name region -> rax = the value as a region, or 0 when unset.
rt_env:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, [rip+envp_ptr]
.re_next:
    mov r14, [r13]
    test r14, r14
    jz .re_none
    mov rcx, [r12]
    xor rdx, rdx
.re_cmp:
    cmp rdx, rcx
    jge .re_eq
    movzx r8, byte ptr [r14 + rdx]
    mov r9, [r12 + rdx*8 + 8]
    cmp r8, r9
    jne .re_adv
    inc rdx
    jmp .re_cmp
.re_eq:
    cmp byte ptr [r14 + rdx], 61
    jne .re_adv
    lea rsi, [r14 + rdx + 1]
    call rt_cstr_region
    jmp .re_out
.re_adv:
    add r13, 8
    jmp .re_next
.re_none:
    xor rax, rax
.re_out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rt_random: -> rax = a non-negative random number, from getrandom(2).
rt_random:
    lea rdi, [rip+numscratch]
    mov rsi, 8
    xor rdx, rdx
    mov rax, 318
    syscall
    lea rsi, [rip+numscratch]
    mov rax, [rsi]
    movabs rcx, 0x7fffffffffffffff
    and rax, rcx
    ret

# rt_dir: rdi = path region -> rax = a byte region holding the entry names
# joined by newlines, including . and .. (spec 12.1), or the number 0 when the
# path will not open. Names are accumulated in a scratch buffer first, because
# the total length is not known until the last getdents64 comes back.
rt_dir:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call rt_pathcstr
    mov rax, 2
    lea rdi, [rip+pathbuf]
    mov rsi, 0x10000
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .rd_fail
    mov r15, rax
    xor r14, r14                    # bytes staged in dirout
.rd_read:
    mov rax, 217
    mov rdi, r15
    lea rsi, [rip+dirbuf]
    mov rdx, 32768
    syscall
    cmp rax, 0
    jle .rd_close
    mov r13, rax
    xor r12, r12
.rd_ent:
    cmp r12, r13
    jge .rd_read
    lea rbx, [rip+dirbuf]
    add rbx, r12
    movzx rcx, word ptr [rbx + 16]  # d_reclen
    add rbx, 19                     # d_name
    push rcx
.rd_name:
    movzx rax, byte ptr [rbx]
    test rax, rax
    jz .rd_nl
    cmp r14, 65500
    jge .rd_nl
    lea rdx, [rip+dirout]
    mov [rdx + r14], al
    inc r14
    inc rbx
    jmp .rd_name
.rd_nl:
    lea rdx, [rip+dirout]
    mov byte ptr [rdx + r14], 10
    inc r14
    pop rcx
    add r12, rcx
    jmp .rd_ent
.rd_close:
    mov rax, 3
    mov rdi, r15
    syscall
    mov rdi, r14
    inc rdi
    shl rdi, 3
    call rt_alloc
    mov [rax], r14
    mov rbx, rax
    xor rcx, rcx
.rd_copy:
    cmp rcx, r14
    jge .rd_ok
    lea rdx, [rip+dirout]
    movzx r8, byte ptr [rdx + rcx]
    mov [rbx + rcx*8 + 8], r8
    inc rcx
    jmp .rd_copy
.rd_ok:
    mov rax, rbx
    jmp .rd_out
.rd_fail:
    xor rax, rax
.rd_out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ---- maps -------------------------------------------------------------------
#
# A map is a BOX, a 2-element region. Its first element points at a `pairs`
# region holding k0, v0, k1, v1, ... in insertion order. The box never moves, so
# a name bound to a map stays valid while the pairs region is reallocated
# underneath it, which is why there's a box at all.
#
# The box's second element points at the box itself. No ordinary region does
# that, so it's how copy() and kind() tell a map from a region without an
# immediate. It also means len(m) answers 2, the box's length, not the number
# of keys. word.w never asks.
#
# Lookup is a linear scan: this seed compiles compiler/word.w once, and word.w's
# largest map is its function table at a few hundred entries, so a hash wouldn't
# pay for itself.
#
# rt_map_new: -> rax = an empty map
rt_map_new:
    push rbx
    mov rdi, 8
    call rt_alloc
    mov qword ptr [rax], 0
    mov rbx, rax
    mov rdi, 24
    call rt_alloc
    mov qword ptr [rax], 2
    mov [rax + 8], rbx
    mov [rax + 16], rax             # element 1 points at the box itself
    pop rbx
    ret

# rt_map_find: rdi = map, rsi = key -> rax = pair index, or -1
rt_map_find:
    push rbx
    push r12
    push r13
    push r14
    mov r12, [rdi + 8]
    mov r13, rsi
    mov r14, [r12]
    xor rbx, rbx
.mf_loop:
    cmp rbx, r14
    jge .mf_none
    mov rdi, [r12 + rbx*8 + 8]
    mov rsi, r13
    call rt_eq
    test rax, rax
    jnz .mf_hit
    add rbx, 2
    jmp .mf_loop
.mf_hit:
    mov rax, rbx
    jmp .mf_done
.mf_none:
    mov rax, -1
.mf_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rt_map_get: rdi = map, rsi = key -> rax = value, or 0 when absent (spec 3.7)
rt_map_get:
    push rbx
    mov rbx, rdi
    call rt_map_find
    cmp rax, 0
    jl .mg_absent
    mov rcx, [rbx + 8]
    mov rax, [rcx + rax*8 + 16]
    pop rbx
    ret
.mg_absent:
    xor rax, rax
    pop rbx
    ret

# rt_map_has: rdi = map, rsi = key -> rax in {0,1}
rt_map_has:
    call rt_map_find
    cmp rax, 0
    setge al
    movzx rax, al
    ret

# rt_map_set: rdi = map, rsi = key, rdx = value. Replaces in place when the key
# is already present, so a repeated key keeps its first position and last value.
rt_map_set:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call rt_map_find
    cmp rax, 0
    jl .ms_append
    mov rcx, [rbx + 8]
    mov [rcx + rax*8 + 16], r13
    jmp .ms_done
.ms_append:
    mov r14, [rbx + 8]
    mov r15, [r14]
    mov rdi, r15
    add rdi, 3
    shl rdi, 3
    call rt_alloc
    mov rcx, r15
    add rcx, 2
    mov [rax], rcx
    xor rcx, rcx
.ms_copy:
    cmp rcx, r15
    jge .ms_tail
    mov rdx, [r14 + rcx*8 + 8]
    mov [rax + rcx*8 + 8], rdx
    inc rcx
    jmp .ms_copy
.ms_tail:
    mov [rax + r15*8 + 8], r12
    mov [rax + r15*8 + 16], r13
    mov [rbx + 8], rax
.ms_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rt_map_copy: rdi = map -> rax = an independent map over the same pairs.
# Shallow, the same as copy() of a region.
rt_map_copy:
    push rbx
    push r12
    push r13
    mov r12, [rdi + 8]
    mov r13, [r12]
    mov rdi, r13
    inc rdi
    shl rdi, 3
    call rt_alloc
    mov [rax], r13
    mov rbx, rax
    xor rcx, rcx
.mc_copy:
    cmp rcx, r13
    jge .mc_box
    mov rdx, [r12 + rcx*8 + 8]
    mov [rbx + rcx*8 + 8], rdx
    inc rcx
    jmp .mc_copy
.mc_box:
    mov rdi, 24
    call rt_alloc
    mov qword ptr [rax], 2
    mov [rax + 8], rbx
    mov [rax + 16], rax
    pop r13
    pop r12
    pop rbx
    ret

# equality: rdi=a, rsi=b -> rax in {0,1}. numbers by value, regions by content, mixed=0
rt_eq:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    call rt_isreg
    mov rbx, rax
    mov rdi, r13
    call rt_isreg
    cmp rbx, rax
    jne .eq_false
    test rbx, rbx
    jnz .eq_reg
    cmp r12, r13
    je .eq_true
    jmp .eq_false
.eq_reg:
    mov r8, [r12]
    mov r9, [r13]
    cmp r8, r9
    jne .eq_false
    xor rcx, rcx
.eq_loop:
    cmp rcx, r8
    jge .eq_true
    mov rax, [r12 + rcx*8 + 8]
    mov rdx, [r13 + rcx*8 + 8]
    cmp rax, rdx
    jne .eq_false
    inc rcx
    jmp .eq_loop
.eq_true:
    mov rax, 1
    jmp .eq_done
.eq_false:
    xor rax, rax
.eq_done:
    pop r13
    pop r12
    pop rbx
    ret

# order: rdi=a, rsi=b -> rax in {-1,0,1}. numbers signed, regions lexicographic, mixed=fault
rt_order:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    call rt_isreg
    mov rbx, rax
    mov rdi, r13
    call rt_isreg
    cmp rbx, rax
    jne rt_ordfault
    test rbx, rbx
    jnz .ord_reg
    cmp r12, r13
    jl .ord_lt
    jg .ord_gt
    jmp .ord_eq
.ord_reg:
    mov r8, [r12]
    mov r9, [r13]
    xor rcx, rcx
.ord_loop:
    cmp rcx, r8
    jge .ord_endlen
    cmp rcx, r9
    jge .ord_endlen
    mov rax, [r12 + rcx*8 + 8]
    mov rdx, [r13 + rcx*8 + 8]
    cmp rax, rdx
    jl .ord_lt
    jg .ord_gt
    inc rcx
    jmp .ord_loop
.ord_endlen:
    cmp r8, r9
    jl .ord_lt
    jg .ord_gt
.ord_eq:
    xor rax, rax
    jmp .ord_done
.ord_lt:
    mov rax, -1
    jmp .ord_done
.ord_gt:
    mov rax, 1
.ord_done:
    pop r13
    pop r12
    pop rbx
    ret

# out one code point as UTF-8; rdi = code point
rt_utf8:
    push rbx
    mov rax, rdi
    cmp rax, 0
    jl .u_bad
    lea rsi, [rip+utf8buf]
    cmp rax, 0x80
    jge .u_2
    mov [rsi], al
    mov rdx, 1
    jmp .u_write
.u_2:
    cmp rax, 0x800
    jge .u_3
    mov rbx, rax
    shr rbx, 6
    or bl, 0xC0
    mov [rsi], bl
    mov rbx, rax
    and bl, 0x3F
    or bl, 0x80
    mov [rsi+1], bl
    mov rdx, 2
    jmp .u_write
.u_3:
    cmp rax, 0xD800
    jl .u_3ok
    cmp rax, 0xDFFF
    jle .u_bad
.u_3ok:
    cmp rax, 0x10000
    jge .u_4
    mov rbx, rax
    shr rbx, 12
    or bl, 0xE0
    mov [rsi], bl
    mov rbx, rax
    shr rbx, 6
    and bl, 0x3F
    or bl, 0x80
    mov [rsi+1], bl
    mov rbx, rax
    and bl, 0x3F
    or bl, 0x80
    mov [rsi+2], bl
    mov rdx, 3
    jmp .u_write
.u_4:
    cmp rax, 0x10FFFF
    jg .u_bad
    mov rbx, rax
    shr rbx, 18
    or bl, 0xF0
    mov [rsi], bl
    mov rbx, rax
    shr rbx, 12
    and bl, 0x3F
    or bl, 0x80
    mov [rsi+1], bl
    mov rbx, rax
    shr rbx, 6
    and bl, 0x3F
    or bl, 0x80
    mov [rsi+2], bl
    mov rbx, rax
    and bl, 0x3F
    or bl, 0x80
    mov [rsi+3], bl
    mov rdx, 4
.u_write:
    mov rax, 1
    mov rdi, [rip+out_fd]
    lea rsi, [rip+utf8buf]
    syscall
    pop rbx
    ret
.u_bad:
    lea rdi, [rip+err_char]
    mov rsi, {LEN_CHAR}
    jmp rt_fail

# out a region as UTF-8; rdi = region ptr
rt_out_region:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, [r12]
    xor rbx, rbx
.outr_loop:
    cmp rbx, r13
    jge .outr_done
    mov rdi, [r12 + rbx*8 + 8]
    call rt_utf8
    inc rbx
    jmp .outr_loop
.outr_done:
    pop r13
    pop r12
    pop rbx
    ret

# put a number as decimal; rdi = n, rsi = fd
rt_putnum:
    push rbx
    push r12
    push r13
    push r14
    mov r14, rsi
    mov rax, rdi
    test rax, rax
    jnz .pn_nz
    lea rsi, [rip+numscratch]
    mov byte ptr [rsi], 48
    mov rdx, 1
    mov rax, 1
    mov rdi, r14
    syscall
    jmp .pn_done
.pn_nz:
    xor r13, r13
    cmp rax, 0
    jge .pn_pos
    mov r13, 1
    neg rax
.pn_pos:
    lea rbx, [rip+numscratch]
    mov r12, 31
    mov rcx, 10
.pn_loop:
    xor rdx, rdx
    div rcx
    add dl, 48
    mov [rbx + r12], dl
    dec r12
    test rax, rax
    jnz .pn_loop
    test r13, r13
    jz .pn_nosign
    mov byte ptr [rbx + r12], 45
    dec r12
.pn_nosign:
    lea rsi, [rbx + r12 + 1]
    mov rdx, 31
    sub rdx, r12
    mov rax, 1
    mov rdi, r14
    syscall
.pn_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# out a number as decimal to stdout; rdi = n
rt_out_num:
    mov rsi, 1
    jmp rt_putnum

# out dispatch: rdi = value; always ends with a newline (spec 9.1)
rt_out:
    call rt_isreg
    test rax, rax
    jnz .out_reg
    call rt_out_num
    jmp .out_nl
.out_reg:
    call rt_out_region
.out_nl:
    lea rsi, [rip+numscratch]
    mov byte ptr [rsi], 10
    mov rax, 1
    mov rdi, [rip+out_fd]
    mov rdx, 1
    syscall
    ret

# ----- stdin input -----
# refill inbuf from stdin if empty
rt_fill:
    mov rax, [rip+inbuf_pos]
    cmp rax, [rip+inbuf_len]
    jl .fill_done
    mov rax, [rip+in_eof]
    test rax, rax
    jnz .fill_done
    xor rax, rax
    xor rdi, rdi
    lea rsi, [rip+inbuf]
    mov rdx, 65536
    syscall
    cmp rax, 0
    jg .fill_got
    mov qword ptr [rip+in_eof], 1
    mov qword ptr [rip+inbuf_len], 0
    mov qword ptr [rip+inbuf_pos], 0
    jmp .fill_done
.fill_got:
    mov [rip+inbuf_len], rax
    mov qword ptr [rip+inbuf_pos], 0
.fill_done:
    ret

# next input byte in rax, or -1 at EOF
rt_getbyte:
    call rt_fill
    mov r10, [rip+inbuf_pos]
    cmp r10, [rip+inbuf_len]
    jl .gb_have
    mov rax, -1
    ret
.gb_have:
    lea rcx, [rip+inbuf]
    movzx rax, byte ptr [rcx + r10]
    inc r10
    mov [rip+inbuf_pos], r10
    ret

# 1 if stdin exhausted, else 0
rt_eof:
    call rt_fill
    mov rax, [rip+inbuf_pos]
    cmp rax, [rip+inbuf_len]
    jl .eof_no
    mov rax, [rip+in_eof]
    ret
.eof_no:
    xor rax, rax
    ret

# read a line: a number if it is an integer, else a text region
rt_readline:
    push rbx
    push r12
    push r13
    xor r12, r12
.rl_read:
    call rt_getbyte
    cmp rax, -1
    je .rl_eol
    cmp rax, 10
    je .rl_eol
    lea rcx, [rip+linebuf]
    mov [rcx + r12], al
    inc r12
    cmp r12, 65536
    jge .rl_eol
    jmp .rl_read
.rl_eol:
    lea rbx, [rip+linebuf]
    xor rcx, rcx
    xor r13, r13
    test r12, r12
    jz .rl_text
    movzx rax, byte ptr [rbx]
    cmp rax, 45
    jne .rl_chkdig
    mov r13, 1
    mov rcx, 1
    cmp r12, 1
    je .rl_text
.rl_chkdig:
    mov rax, r12
    sub rax, rcx
    cmp rax, 18
    jg .rl_text
    mov r10, rcx
.rl_dloop:
    cmp r10, r12
    jge .rl_isint
    movzx rax, byte ptr [rbx + r10]
    cmp rax, 48
    jl .rl_text
    cmp rax, 57
    jg .rl_text
    inc r10
    jmp .rl_dloop
.rl_isint:
    xor rax, rax
    mov r10, rcx
.rl_ploop:
    cmp r10, r12
    jge .rl_intdone
    movzx r11, byte ptr [rbx + r10]
    sub r11, 48
    imul rax, rax, 10
    add rax, r11
    inc r10
    jmp .rl_ploop
.rl_intdone:
    test r13, r13
    jz .rl_intret
    neg rax
.rl_intret:
    pop r13
    pop r12
    pop rbx
    ret
.rl_text:
    mov rax, r12
    inc rax
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    mov rbx, rax
    xor r10, r10
    xor rcx, rcx
    lea r8, [rip+linebuf]
.dec_loop:
    cmp r10, r12
    jge .dec_done
    movzx rax, byte ptr [r8 + r10]
    inc r10
    cmp rax, 0x80
    jl .dec_store
    cmp rax, 0xE0
    jl .dec_2
    cmp rax, 0xF0
    jl .dec_3
    and rax, 0x07
    push rcx
    mov rcx, 3
    jmp .dec_cont
.dec_2:
    and rax, 0x1F
    push rcx
    mov rcx, 1
    jmp .dec_cont
.dec_3:
    and rax, 0x0F
    push rcx
    mov rcx, 2
.dec_cont:
    mov rdx, rcx
    pop rcx
.dec_cloop:
    test rdx, rdx
    jz .dec_store
    cmp r10, r12
    jge .dec_store
    movzx r9, byte ptr [r8 + r10]
    inc r10
    and r9, 0x3F
    shl rax, 6
    or rax, r9
    dec rdx
    jmp .dec_cloop
.dec_store:
    mov [rbx + rcx*8 + 8], rax
    inc rcx
    jmp .dec_loop
.dec_done:
    mov [rbx], rcx
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
    ret

# slice: rdi=s, rsi=i, rdx=n -> rax = new region
rt_slice:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r12
    call rt_isreg
    test rax, rax
    jz rt_regfault
    cmp r13, 0
    jl rt_bounds
    cmp r14, 0
    jl rt_bounds
    mov rax, r13
    add rax, r14
    mov rcx, [r12]
    cmp rax, rcx
    jg rt_bounds
    mov rax, r14
    inc rax
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    mov rbx, rax
    mov [rbx], r14
    xor rcx, rcx
.slice_loop:
    cmp rcx, r14
    jge .slice_done
    mov rax, r13
    add rax, rcx
    mov rdx, [r12 + rax*8 + 8]
    mov [rbx + rcx*8 + 8], rdx
    inc rcx
    jmp .slice_loop
.slice_done:
    mov rax, rbx
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ----- fs module: files via syscalls -----
# copy a path region into pathbuf as a null-terminated byte string
rt_pathcstr:
    push rbx
    mov rbx, rdi
    mov rcx, [rbx]
    lea r8, [rip+pathbuf]
    xor r9, r9
.pc_loop:
    cmp r9, rcx
    jge .pc_done
    cmp r9, 4094
    jge .pc_done
    mov rax, [rbx + r9*8 + 8]
    mov [r8 + r9], al
    inc r9
    jmp .pc_loop
.pc_done:
    mov byte ptr [r8 + r9], 0
    pop rbx
    ret

# read whole file: rdi = path region -> rax = region of bytes, or 0
rt_read:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call rt_pathcstr
    mov rax, 2
    lea rdi, [rip+pathbuf]
    xor rsi, rsi
    xor rdx, rdx
    syscall
    cmp rax, 0
    jl .read_fail
    mov r12, rax
    # Size the region from the file rather than guessing: an exact fstat is one
    # allocation and no copying for a regular file, and the arena only ever
    # bumps, so an over-guess is memory nothing gets back. A pipe or a /proc
    # entry reports 0 and falls back to a small start plus the doubling below.
    mov rax, 5
    mov rdi, r12
    lea rsi, [rip+statbuf]
    syscall
    mov r14, [rsi + 48]
    cmp r14, 0
    jg .read_cap
    mov r14, 4096
.read_cap:
    mov rdi, r14
    inc rdi
    shl rdi, 3
    call rt_alloc
    mov rbx, rax
    xor r13, r13
.read_loop:
    mov rax, 0
    mov rdi, r12
    lea rsi, [rip+filebuf]
    mov rdx, 1048576
    syscall
    cmp rax, 0
    jle .read_eof
    mov r15, rax
    mov rcx, r13
    add rcx, r15
    cmp rcx, r14
    jle .read_room
.read_dbl:
    shl r14, 1
    cmp r14, rcx
    jl .read_dbl
    mov rdi, r14
    inc rdi
    shl rdi, 3
    call rt_alloc
    xor rcx, rcx
.read_move:
    cmp rcx, r13
    jge .read_moved
    mov rdx, [rbx + rcx*8 + 8]
    mov [rax + rcx*8 + 8], rdx
    inc rcx
    jmp .read_move
.read_moved:
    mov rbx, rax
.read_room:
    lea r8, [rip+filebuf]
    xor rcx, rcx
.read_copy:
    cmp rcx, r15
    jge .read_copied
    movzx rax, byte ptr [r8 + rcx]
    mov rdx, r13
    add rdx, rcx
    mov [rbx + rdx*8 + 8], rax
    inc rcx
    jmp .read_copy
.read_copied:
    add r13, r15
    jmp .read_loop
.read_eof:
    mov rax, 3
    mov rdi, r12
    syscall
    mov [rbx], r13
    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.read_fail:
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# write/append: rdi = path, rsi = data, rdx = append flag -> rax = 1/0
rt_writef:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r13, rsi
    mov r15, rdx
    call rt_pathcstr
    mov rax, 2
    lea rdi, [rip+pathbuf]
    test r15, r15
    jnz .w_append
    mov rsi, 0x241
    jmp .w_open
.w_append:
    mov rsi, 0x441
.w_open:
    mov rdx, 0x1A4
    syscall
    cmp rax, 0
    jl .w_fail
    mov r12, rax
    mov r14, [r13]
    xor r15, r15
.w_chunk:
    cmp r15, r14
    jge .w_done
    lea r8, [rip+filebuf]
    xor rcx, rcx
.w_fill:
    cmp rcx, 1048576
    jge .w_flush
    mov rax, r15
    add rax, rcx
    cmp rax, r14
    jge .w_flush
    mov rdx, [r13 + rax*8 + 8]
    mov [r8 + rcx], dl
    inc rcx
    jmp .w_fill
.w_flush:
    mov rbx, rcx
    mov rax, 1
    mov rdi, r12
    lea rsi, [rip+filebuf]
    mov rdx, rcx
    syscall
    add r15, rbx
    jmp .w_chunk
.w_done:
    mov rax, 3
    mov rdi, r12
    syscall
    mov rax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.w_fail:
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ----- sys module: emit buffer, executable output, exec, self-location -----
# rt_asmput: rdi = region s -> append s's elements then a newline to the emit
# buffer, growing it (doubling) as needed. The emit buffer is a region whose
# [0] is its length; em() funnels every emitted asm line through here.
rt_asmput:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r13, [rbx]
    mov r12, [rip+emit_ptr]
    test r12, r12
    jnz .ap_have
    mov r14, 2097152
    mov rdi, r14
    inc rdi
    shl rdi, 3
    call rt_alloc
    mov r12, rax
    mov qword ptr [r12], 0
    mov [rip+emit_ptr], r12
    mov [rip+emit_cap], r14
.ap_have:
    mov r14, [r12]
    mov rax, r14
    add rax, r13
    inc rax
    mov rcx, [rip+emit_cap]
    cmp rax, rcx
    jle .ap_fits
    shl rcx, 1
    cmp rcx, rax
    jge .ap_newcap
    mov rcx, rax
.ap_newcap:
    push rcx
    mov rdi, rcx
    inc rdi
    shl rdi, 3
    call rt_alloc
    pop rcx
    mov r15, rax
    mov [r15], r14
    xor rdx, rdx
.ap_copy:
    cmp rdx, r14
    jge .ap_copied
    mov rax, [r12 + rdx*8 + 8]
    mov [r15 + rdx*8 + 8], rax
    inc rdx
    jmp .ap_copy
.ap_copied:
    mov r12, r15
    mov [rip+emit_ptr], r12
    mov [rip+emit_cap], rcx
.ap_fits:
    xor rcx, rcx
.ap_put:
    cmp rcx, r13
    jge .ap_putd
    mov rax, [rbx + rcx*8 + 8]
    mov rdx, r14
    add rdx, rcx
    mov [r12 + rdx*8 + 8], rax
    inc rcx
    jmp .ap_put
.ap_putd:
    mov rdx, r14
    add rdx, r13
    mov qword ptr [r12 + rdx*8 + 8], 10
    add r14, r13
    inc r14
    mov [r12], r14
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rt_asmtake: -> rax = the accumulated emit-buffer region; resets so the next
# asmput starts a fresh buffer. With no buffer yet, returns an empty region.
rt_asmtake:
    mov rax, [rip+emit_ptr]
    test rax, rax
    jz .at_empty
    mov qword ptr [rip+emit_ptr], 0
    ret
.at_empty:
    mov rdi, 8
    call rt_alloc
    mov qword ptr [rax], 0
    ret

# rt_writex: rdi = path region, rsi = data region (one byte value per element)
# -> rax = 1/0. Writes an executable (mode 0755), truncating, in filebuf-sized
# chunks so the output size is unbounded (an ELF may exceed 1 MB).
rt_writex:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r13, rsi
    call rt_pathcstr
    mov rax, 2
    lea rdi, [rip+pathbuf]
    mov rsi, 0x241
    mov rdx, 0x1ED
    syscall
    cmp rax, 0
    jl .wx_fail
    mov r12, rax
    mov r14, [r13]
    xor r15, r15
.wx_chunk:
    cmp r15, r14
    jge .wx_done
    lea r8, [rip+filebuf]
    xor rcx, rcx
.wx_fill:
    cmp rcx, 1048576
    jge .wx_flush
    mov rax, r15
    add rax, rcx
    cmp rax, r14
    jge .wx_flush
    mov rdx, [r13 + rax*8 + 8]
    mov [r8 + rcx], dl
    inc rcx
    jmp .wx_fill
.wx_flush:
    mov rbx, rcx
    mov rax, 1
    mov rdi, r12
    lea rsi, [rip+filebuf]
    mov rdx, rcx
    syscall
    add r15, rbx
    jmp .wx_chunk
.wx_done:
    mov rax, 3
    mov rdi, r12
    syscall
    mov rax, 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.wx_fail:
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rt_exec: rdi = path region, rsi = args region (each element a byte region) ->
# execve(path, [path, args...], envp inherited). Returns rax=0 only on failure;
# on success the image is replaced. C strings are laid out in execbuf, their
# addresses collected in execargv (the argv array, NULL-terminated).
rt_exec:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    lea r14, [rip+execbuf]
    lea r15, [rip+execargv]
    mov [r15], r14
    add r15, 8
    mov rcx, [r12]
    xor rdx, rdx
.ex_pcp:
    cmp rdx, rcx
    jge .ex_pdone
    mov rax, [r12 + rdx*8 + 8]
    mov [r14], al
    inc r14
    inc rdx
    jmp .ex_pcp
.ex_pdone:
    mov byte ptr [r14], 0
    inc r14
    mov rbx, [r13 + 8]
    xor r9, r9
.ex_arg:
    cmp r9, rbx
    jge .ex_argsdone
    mov r8, [r13 + r9*8 + 16]
    mov [r15], r14
    add r15, 8
    mov rcx, [r8]
    xor rdx, rdx
.ex_acp:
    cmp rdx, rcx
    jge .ex_adone
    mov rax, [r8 + rdx*8 + 8]
    mov [r14], al
    inc r14
    inc rdx
    jmp .ex_acp
.ex_adone:
    mov byte ptr [r14], 0
    inc r14
    inc r9
    jmp .ex_arg
.ex_argsdone:
    mov qword ptr [r15], 0
    mov rax, 59
    lea rdi, [rip+execbuf]
    lea rsi, [rip+execargv]
    mov rdx, [rip+envp_ptr]
    syscall
    xor rax, rax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ----- net module: plain HTTP/1.1 over raw TCP + hand-rolled DNS (no TLS) -----
rt_dns_skipname:
    lea r8, [rip+dnsr]
.skn_loop:
    movzx rax, byte ptr [r8 + rdi]
    test rax, rax
    jz .skn_zero
    mov rcx, rax
    and rcx, 0xC0
    cmp rcx, 0xC0
    je .skn_ptr
    add rdi, rax
    inc rdi
    jmp .skn_loop
.skn_ptr:
    add rdi, 2
    mov rax, rdi
    ret
.skn_zero:
    inc rdi
    mov rax, rdi
    ret

# resolve nethost (cstring) -> 4 IP bytes at netsa+4; rax = 1 ok / 0 fail
rt_dns:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rbx, [rip+dnsq]
    mov word ptr [rbx], 0x3412
    mov word ptr [rbx+2], 0x0001
    mov word ptr [rbx+4], 0x0100
    mov word ptr [rbx+6], 0
    mov word ptr [rbx+8], 0
    mov word ptr [rbx+10], 0
    mov r12, 12
    lea r13, [rip+nethost]
    xor r14, r14
    xor r15, r15
.dns_emit:
    movzx rax, byte ptr [r13 + r14]
    test rax, rax
    jz .dns_last
    cmp rax, 46
    jne .dns_scan
    mov rcx, r14
    sub rcx, r15
    mov [rbx + r12], cl
    inc r12
.dns_c1:
    cmp r15, r14
    jge .dns_c1d
    movzx rax, byte ptr [r13 + r15]
    mov [rbx + r12], al
    inc r12
    inc r15
    jmp .dns_c1
.dns_c1d:
    inc r15
.dns_scan:
    inc r14
    jmp .dns_emit
.dns_last:
    mov rcx, r14
    sub rcx, r15
    mov [rbx + r12], cl
    inc r12
.dns_c2:
    cmp r15, r14
    jge .dns_c2d
    movzx rax, byte ptr [r13 + r15]
    mov [rbx + r12], al
    inc r12
    inc r15
    jmp .dns_c2
.dns_c2d:
    mov byte ptr [rbx + r12], 0
    inc r12
    mov word ptr [rbx + r12], 0x0100
    add r12, 2
    mov word ptr [rbx + r12], 0x0100
    add r12, 2
    lea rbx, [rip+dnssa]
    mov word ptr [rbx], 2
    mov byte ptr [rbx+2], 0
    mov byte ptr [rbx+3], 0x35
    mov byte ptr [rbx+4], 8
    mov byte ptr [rbx+5], 8
    mov byte ptr [rbx+6], 8
    mov byte ptr [rbx+7], 8
    mov rax, 41
    mov rdi, 2
    mov rsi, 2
    xor rdx, rdx
    syscall
    test rax, rax
    js .dns_fail
    mov r13, rax
    mov rax, 42
    mov rdi, r13
    lea rsi, [rip+dnssa]
    mov rdx, 16
    syscall
    test rax, rax
    js .dns_cfail
    mov rax, 1
    mov rdi, r13
    lea rsi, [rip+dnsq]
    mov rdx, r12
    syscall
    mov rax, 0
    mov rdi, r13
    lea rsi, [rip+dnsr]
    mov rdx, 512
    syscall
    mov r14, rax
    mov rax, 3
    mov rdi, r13
    syscall
    cmp r14, 12
    jl .dns_fail
    lea r8, [rip+dnsr]
    movzx r15, byte ptr [r8+6]
    shl r15, 8
    movzx rax, byte ptr [r8+7]
    or r15, rax
    test r15, r15
    jz .dns_fail
    mov rdi, 12
    call rt_dns_skipname
    mov rdi, rax
    add rdi, 4
.dns_ans:
    test r15, r15
    jz .dns_fail
    call rt_dns_skipname
    mov rdi, rax
    lea r8, [rip+dnsr]
    movzx rcx, byte ptr [r8+rdi]
    shl rcx, 8
    movzx rax, byte ptr [r8+rdi+1]
    or rcx, rax
    movzx rdx, byte ptr [r8+rdi+8]
    shl rdx, 8
    movzx rax, byte ptr [r8+rdi+9]
    or rdx, rax
    cmp rcx, 1
    jne .dns_next
    cmp rdx, 4
    jne .dns_next
    lea r9, [rip+netsa]
    mov al, [r8+rdi+10]
    mov [r9+4], al
    mov al, [r8+rdi+11]
    mov [r9+5], al
    mov al, [r8+rdi+12]
    mov [r9+6], al
    mov al, [r8+rdi+13]
    mov [r9+7], al
    mov rax, 1
    jmp .dns_ret
.dns_next:
    add rdi, 10
    add rdi, rdx
    dec r15
    jmp .dns_ans
.dns_cfail:
    mov rax, 3
    mov rdi, r13
    syscall
.dns_fail:
    xor rax, rax
.dns_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# resolve: dotted-quad -> netsa+4 directly, else DNS; rax = 1/0
rt_resolve:
    lea r8, [rip+nethost]
    xor r9, r9
    xor r10, r10
.res_oct:
    movzx rax, byte ptr [r8+r9]
    cmp rax, 48
    jl rt_dns
    cmp rax, 57
    jg rt_dns
    xor r11, r11
.res_dig:
    movzx rax, byte ptr [r8+r9]
    cmp rax, 48
    jl .res_od
    cmp rax, 57
    jg .res_od
    sub rax, 48
    imul r11, r11, 10
    add r11, rax
    inc r9
    jmp .res_dig
.res_od:
    cmp r11, 255
    jg rt_dns
    lea rdx, [rip+netsa]
    mov [rdx + r10 + 4], r11b
    inc r10
    movzx rax, byte ptr [r8+r9]
    test rax, rax
    jz .res_end
    cmp rax, 46
    jne rt_dns
    inc r9
    cmp r10, 4
    jge rt_dns
    jmp .res_oct
.res_end:
    cmp r10, 4
    jne rt_dns
    mov rax, 1
    ret

# net.get: rdi = url region -> rax = response body region, or 0
rt_net_get:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rcx, [r12]
    cmp rcx, 7
    jl .ng_fail
    mov rax, [r12+8]
    cmp rax, 104
    jne .ng_fail
    mov rax, [r12+16]
    cmp rax, 116
    jne .ng_fail
    mov rax, [r12+24]
    cmp rax, 116
    jne .ng_fail
    mov rax, [r12+32]
    cmp rax, 112
    jne .ng_fail
    mov rax, [r12+40]
    cmp rax, 58
    jne .ng_fail
    mov rax, [r12+48]
    cmp rax, 47
    jne .ng_fail
    mov rax, [r12+56]
    cmp rax, 47
    jne .ng_fail
    mov r13, 7
    xor r14, r14
    lea rbx, [rip+nethost]
.ng_host:
    cmp r13, rcx
    jge .ng_hostend
    mov rax, [r12 + r13*8 + 8]
    cmp rax, 58
    je .ng_hostend
    cmp rax, 47
    je .ng_hostend
    mov [rbx + r14], al
    inc r14
    inc r13
    cmp r14, 254
    jl .ng_host
.ng_hostend:
    mov byte ptr [rbx + r14], 0
    mov r15, 80
    cmp r13, rcx
    jge .ng_bld
    mov rax, [r12 + r13*8 + 8]
    cmp rax, 58
    jne .ng_bld
    inc r13
    xor r15, r15
.ng_port:
    cmp r13, rcx
    jge .ng_bld
    mov rax, [r12 + r13*8 + 8]
    cmp rax, 47
    je .ng_bld
    sub rax, 48
    imul r15, r15, 10
    add r15, rax
    inc r13
    jmp .ng_port
.ng_bld:
    lea rbx, [rip+netreq]
    mov byte ptr [rbx+0], 71
    mov byte ptr [rbx+1], 69
    mov byte ptr [rbx+2], 84
    mov byte ptr [rbx+3], 32
    mov r14, 4
    cmp r13, rcx
    jl .ng_pcopy
    mov byte ptr [rbx + r14], 47
    inc r14
    jmp .ng_pdone
.ng_pcopy:
    cmp r13, rcx
    jge .ng_pdone
    mov rax, [r12 + r13*8 + 8]
    mov [rbx + r14], al
    inc r14
    inc r13
    jmp .ng_pcopy
.ng_pdone:
    lea rsi, [rip+http_a]
    lea rdi, [rbx + r14]
    mov rcx, 17
    add r14, rcx
    cld
    rep movsb
    lea rsi, [rip+nethost]
.ng_hcopy:
    movzx rax, byte ptr [rsi]
    test rax, rax
    jz .ng_hdone
    mov [rbx + r14], al
    inc r14
    inc rsi
    jmp .ng_hcopy
.ng_hdone:
    lea rsi, [rip+http_b]
    lea rdi, [rbx + r14]
    mov rcx, 23
    add r14, rcx
    cld
    rep movsb
    call rt_resolve
    test rax, rax
    jz .ng_fail
    lea rbx, [rip+netsa]
    mov word ptr [rbx], 2
    mov rax, r15
    mov rdx, rax
    shr rdx, 8
    mov [rbx+2], dl
    mov [rbx+3], al
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    test rax, rax
    js .ng_fail
    mov r13, rax
    mov rax, 42
    mov rdi, r13
    lea rsi, [rip+netsa]
    mov rdx, 16
    syscall
    test rax, rax
    js .ng_cfail
    mov rax, 1
    mov rdi, r13
    lea rsi, [rip+netreq]
    mov rdx, r14
    syscall
    xor r14, r14
.ng_read:
    mov rdx, 1048576
    sub rdx, r14
    cmp rdx, 0
    jle .ng_rdone
    mov rax, 0
    mov rdi, r13
    lea rsi, [rip+filebuf]
    add rsi, r14
    syscall
    cmp rax, 0
    jle .ng_rdone
    add r14, rax
    jmp .ng_read
.ng_rdone:
    mov rax, 3
    mov rdi, r13
    syscall
    lea r8, [rip+filebuf]
    xor rcx, rcx
    mov r15, -1
.ng_find:
    mov rax, rcx
    add rax, 4
    cmp rax, r14
    jg .ng_found
    cmp byte ptr [r8+rcx], 13
    jne .ng_fnext
    cmp byte ptr [r8+rcx+1], 10
    jne .ng_fnext
    cmp byte ptr [r8+rcx+2], 13
    jne .ng_fnext
    cmp byte ptr [r8+rcx+3], 10
    jne .ng_fnext
    lea r15, [rcx+4]
    jmp .ng_found
.ng_fnext:
    inc rcx
    jmp .ng_find
.ng_found:
    cmp r15, -1
    jne .ng_body
    xor r15, r15
.ng_body:
    mov r13, r14
    sub r13, r15
    mov rax, r13
    inc rax
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    mov rbx, rax
    mov [rbx], r13
    lea r8, [rip+filebuf]
    add r8, r15
    xor rcx, rcx
.ng_copy:
    cmp rcx, r13
    jge .ng_cdone
    movzx rax, byte ptr [r8 + rcx]
    mov [rbx + rcx*8 + 8], rax
    inc rcx
    jmp .ng_copy
.ng_cdone:
    mov rax, rbx
    jmp .ng_ret
.ng_cfail:
    mov rax, 3
    mov rdi, r13
    syscall
.ng_fail:
    xor rax, rax
.ng_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# ----- fault handlers: write message to stderr, exit 70 -----
rt_fail:
    mov r14, rdi
    mov r15, rsi
    mov rax, 1
    mov rdi, 2
    lea rsi, [rip+err_prefix]
    mov rdx, {LEN_PREFIX}
    syscall
    mov rax, 1
    mov rdi, 2
    mov rsi, r14
    mov rdx, r15
    syscall
    mov rax, 1
    mov rdi, 2
    lea rsi, [rip+at_line]
    mov rdx, 9
    syscall
    mov rdi, [rip+cur_line]
    mov rsi, 2
    call rt_putnum
    mov rax, 1
    mov rdi, 2
    lea rsi, [rip+nl_msg]
    mov rdx, 1
    syscall
    mov rax, 60
    mov rdi, 70
    syscall
rt_div0:
    lea rdi, [rip+err_div]
    mov rsi, {LEN_DIV}
    jmp rt_fail
rt_bounds:
    lea rdi, [rip+err_bounds]
    mov rsi, {LEN_BOUNDS}
    jmp rt_fail
rt_oom:
    lea rdi, [rip+err_oom]
    mov rsi, {LEN_OOM}
    jmp rt_fail
rt_shift:
    lea rdi, [rip+err_shift]
    mov rsi, {LEN_SHIFT}
    jmp rt_fail
rt_wrlit:
    lea rdi, [rip+err_wrlit]
    mov rsi, {LEN_WRLIT}
    jmp rt_fail
rt_ordfault:
    lea rdi, [rip+err_ordcmp]
    mov rsi, {LEN_ORDCMP}
    jmp rt_fail
rt_mapfail:
    lea rdi, [rip+err_map]
    mov rsi, {LEN_MAP}
    jmp rt_fail
rt_overflow:
    lea rdi, [rip+err_overflow]
    mov rsi, {LEN_OVERFLOW}
    jmp rt_fail
rt_numfault:
    lea rdi, [rip+err_num]
    mov rsi, {LEN_NUM}
    jmp rt_fail
rt_regfault:
    lea rdi, [rip+err_region]
    mov rsi, {LEN_REGION}
    jmp rt_fail
rt_contract:
    lea rdi, [rip+err_contract]
    mov rsi, {LEN_CONTRACT}
    jmp rt_fail
"""



HTTPX = r"""
# ----- net: unified HTTP/HTTPS with methods, scheme-default, dechunking -----
# (the https path calls https_request, which the seed doesn't define; it's only
# emitted for a program that calls a net verb, and word.w makes no such call)
.text
rt_hx_emit:
    mov r8, [rip+hx_cur]
    lea r9, [rip+hx_req]
    add r9, r8
    xor rcx, rcx
.hxe_l:
    cmp rcx, rdx
    jge .hxe_d
    mov al, [rsi+rcx]
    mov [r9+rcx], al
    inc rcx
    jmp .hxe_l
.hxe_d:
    add r8, rdx
    mov [rip+hx_cur], r8
    ret
rt_hx_num:
    push rbx
    lea rbx, [rip+hx_numbuf+32]
    test rax, rax
    jnz .hxn_conv
    dec rbx
    mov byte ptr [rbx], 48
    jmp .hxn_emit
.hxn_conv:
    mov rcx, 10
.hxn_l:
    xor rdx, rdx
    div rcx
    add dl, 48
    dec rbx
    mov [rbx], dl
    test rax, rax
    jnz .hxn_l
.hxn_emit:
    lea rax, [rip+hx_numbuf+32]
    mov rdx, rax
    sub rdx, rbx
    mov rsi, rbx
    call rt_hx_emit
    pop rbx
    ret

# rt_httpx(rdi=url_region, rsi=method_ptr, rdx=method_len, rcx=body_region_or_0) -> rax=response_region
rt_httpx:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov [rip+hx_method_ptr], rsi
    mov [rip+hx_method_len], rdx
    mov [rip+hx_body], rcx
    mov rcx, [r12]
    mov r13, 0
    mov r14, 1
    cmp rcx, 8
    jl .hx_ckhttp
    mov rax, [r12+8]
    cmp rax, 104
    jne .hx_ckhttp
    mov rax, [r12+16]
    cmp rax, 116
    jne .hx_ckhttp
    mov rax, [r12+24]
    cmp rax, 116
    jne .hx_ckhttp
    mov rax, [r12+32]
    cmp rax, 112
    jne .hx_ckhttp
    mov rax, [r12+40]
    cmp rax, 115
    jne .hx_ckhttp
    mov rax, [r12+48]
    cmp rax, 58
    jne .hx_ckhttp
    mov rax, [r12+56]
    cmp rax, 47
    jne .hx_ckhttp
    mov rax, [r12+64]
    cmp rax, 47
    jne .hx_ckhttp
    mov r13, 8
    mov r14, 1
    jmp .hx_hoststart
.hx_ckhttp:
    cmp rcx, 7
    jl .hx_hoststart
    mov rax, [r12+8]
    cmp rax, 104
    jne .hx_hoststart
    mov rax, [r12+16]
    cmp rax, 116
    jne .hx_hoststart
    mov rax, [r12+24]
    cmp rax, 116
    jne .hx_hoststart
    mov rax, [r12+32]
    cmp rax, 112
    jne .hx_hoststart
    mov rax, [r12+40]
    cmp rax, 58
    jne .hx_hoststart
    mov rax, [r12+48]
    cmp rax, 47
    jne .hx_hoststart
    mov rax, [r12+56]
    cmp rax, 47
    jne .hx_hoststart
    mov r13, 7
    mov r14, 0
.hx_hoststart:
    mov [rip+hx_scheme], r14
    xor r15, r15
    lea rbx, [rip+hx_host]
.hx_hl:
    cmp r13, rcx
    jge .hx_he
    mov rax, [r12+r13*8+8]
    cmp rax, 58
    je .hx_he
    cmp rax, 47
    je .hx_he
    mov [rbx+r15], al
    inc r15
    inc r13
    jmp .hx_hl
.hx_he:
    mov byte ptr [rbx+r15], 0
    mov [rip+hx_hostlen], r15
    mov r8, 443
    test r14, r14
    jnz .hx_pdef
    mov r8, 80
.hx_pdef:
    mov [rip+hx_port], r8
    cmp r13, rcx
    jge .hx_path
    mov rax, [r12+r13*8+8]
    cmp rax, 58
    jne .hx_path
    inc r13
    xor r8, r8
.hx_pl:
    cmp r13, rcx
    jge .hx_pdone
    mov rax, [r12+r13*8+8]
    cmp rax, 47
    je .hx_pdone
    sub rax, 48
    imul r8, r8, 10
    add r8, rax
    inc r13
    jmp .hx_pl
.hx_pdone:
    mov [rip+hx_port], r8
.hx_path:
    lea rbx, [rip+hx_path]
    cmp r13, rcx
    jge .hx_defpath
    xor r15, r15
.hx_ppl:
    cmp r13, rcx
    jge .hx_pathdone
    mov rax, [r12+r13*8+8]
    mov [rbx+r15], al
    inc r15
    inc r13
    jmp .hx_ppl
.hx_pathdone:
    mov [rip+hx_pathlen], r15
    jmp .hx_build
.hx_defpath:
    mov byte ptr [rbx], 47
    mov qword ptr [rip+hx_pathlen], 1
.hx_build:
    mov qword ptr [rip+hx_cur], 0
    mov rsi, [rip+hx_method_ptr]
    mov rdx, [rip+hx_method_len]
    call rt_hx_emit
    lea rsi, [rip+hx_sp]
    mov rdx, 1
    call rt_hx_emit
    lea rsi, [rip+hx_path]
    mov rdx, [rip+hx_pathlen]
    call rt_hx_emit
    lea rsi, [rip+hx_lit_http]
    mov rdx, 17
    call rt_hx_emit
    lea rsi, [rip+hx_host]
    mov rdx, [rip+hx_hostlen]
    call rt_hx_emit
    lea rsi, [rip+hx_lit_hdrs]
    mov rdx, 43
    call rt_hx_emit
    mov rbx, [rip+hx_body]
    test rbx, rbx
    jz .hx_nobody
    lea rsi, [rip+hx_lit_clen]
    mov rdx, 16
    call rt_hx_emit
    mov rax, [rbx]
    call rt_hx_num
    lea rsi, [rip+hx_crlf2]
    mov rdx, 4
    call rt_hx_emit
    mov r15, [rbx]
    mov r8, [rip+hx_cur]
    lea r9, [rip+hx_req]
    add r9, r8
    xor rcx, rcx
.hx_bl:
    cmp rcx, r15
    jge .hx_bd
    mov rax, [rbx+rcx*8+8]
    mov [r9+rcx], al
    inc rcx
    jmp .hx_bl
.hx_bd:
    add r8, r15
    mov [rip+hx_cur], r8
    jmp .hx_reqdone
.hx_nobody:
    lea rsi, [rip+hx_crlf]
    mov rdx, 2
    call rt_hx_emit
.hx_reqdone:
    mov r14, [rip+hx_cur]
    mov rax, [rip+hx_scheme]
    test rax, rax
    jz .hx_httptr
    lea rdi, [rip+hx_host]
    mov rsi, [rip+hx_hostlen]
    lea rdx, [rip+hx_req]
    mov rcx, r14
    call https_request
    test rax, rax
    jz .hx_fail
    lea r13, [rip+https_resp]
    mov r14, rax
    jmp .hx_response
.hx_httptr:
    lea rsi, [rip+hx_host]
    lea rdi, [rip+nethost]
    xor rcx, rcx
.hx_cpnh:
    mov al, [rsi+rcx]
    mov [rdi+rcx], al
    test al, al
    jz .hx_cpnhd
    inc rcx
    jmp .hx_cpnh
.hx_cpnhd:
    call rt_resolve
    test rax, rax
    jz .hx_fail
    lea rbx, [rip+netsa]
    mov word ptr [rbx], 2
    mov rax, [rip+hx_port]
    mov rdx, rax
    shr rdx, 8
    mov [rbx+2], dl
    mov [rbx+3], al
    mov rax, 41
    mov rdi, 2
    mov rsi, 1
    xor rdx, rdx
    syscall
    test rax, rax
    js .hx_fail
    mov r13, rax
    mov rax, 42
    mov rdi, r13
    lea rsi, [rip+netsa]
    mov rdx, 16
    syscall
    test rax, rax
    js .hx_fail
    mov rax, 1
    mov rdi, r13
    lea rsi, [rip+hx_req]
    mov rdx, r14
    syscall
    xor r14, r14
.hx_hrd:
    mov rdx, 4194304
    sub rdx, r14
    cmp rdx, 0
    jle .hx_hrdone
    mov rax, 0
    mov rdi, r13
    lea rsi, [rip+hx_resp]
    add rsi, r14
    syscall
    cmp rax, 0
    jle .hx_hrdone
    add r14, rax
    jmp .hx_hrd
.hx_hrdone:
    mov rax, 3
    mov rdi, r13
    syscall
    lea r13, [rip+hx_resp]
.hx_response:
    mov rdi, r13
    mov rsi, r14
    call rt_build_response
    jmp .hx_ret
.hx_fail:
    xor rax, rax
.hx_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

# rt_build_response(rdi=resp_ptr, rsi=resp_len) -> rax=body region (dechunked if needed)
rt_build_response:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    xor rcx, rcx
    mov r14, -1
.rb_find:
    lea rax, [rcx+4]
    cmp rax, r13
    jg .rb_found
    cmp byte ptr [r12+rcx], 13
    jne .rb_fn
    cmp byte ptr [r12+rcx+1], 10
    jne .rb_fn
    cmp byte ptr [r12+rcx+2], 13
    jne .rb_fn
    cmp byte ptr [r12+rcx+3], 10
    jne .rb_fn
    lea r14, [rcx+4]
    jmp .rb_found
.rb_fn:
    inc rcx
    jmp .rb_find
.rb_found:
    cmp r14, -1
    jne .rb_hok
    xor r14, r14
.rb_hok:
    xor rbx, rbx
.rb_search:
    lea rax, [rbx+7]
    cmp rax, r14
    jg .rb_plain
    lea rsi, [rip+hx_chunked]
    lea rdi, [r12+rbx]
    xor rcx, rcx
.rb_scmp:
    movzx rax, byte ptr [rdi+rcx]
    or rax, 0x20
    movzx rdx, byte ptr [rsi+rcx]
    cmp rax, rdx
    jne .rb_snext
    inc rcx
    cmp rcx, 7
    jl .rb_scmp
    jmp .rb_chunked
.rb_snext:
    inc rbx
    jmp .rb_search
.rb_plain:
    mov r15, r13
    sub r15, r14
    lea r8, [r12+r14]
    jmp .rb_region
.rb_chunked:
    mov rbx, r14
    lea rdi, [rip+hx_dechunk]
    xor r15, r15
.rb_chunk:
    xor r8, r8
.rb_hex:
    cmp rbx, r13
    jge .rb_cdone
    movzx rax, byte ptr [r12+rbx]
    cmp rax, 13
    je .rb_hexend
    cmp rax, 48
    jl .rb_cdone
    cmp rax, 57
    jg .rb_hexa
    sub rax, 48
    jmp .rb_hexadd
.rb_hexa:
    or rax, 0x20
    cmp rax, 97
    jl .rb_cdone
    cmp rax, 102
    jg .rb_cdone
    sub rax, 87
.rb_hexadd:
    shl r8, 4
    add r8, rax
    inc rbx
    jmp .rb_hex
.rb_hexend:
    add rbx, 2
    test r8, r8
    jz .rb_cdone
    lea rsi, [r12+rbx]
    xor rcx, rcx
.rb_ccp:
    cmp rcx, r8
    jge .rb_ccpd
    cmp r15, 4194304
    jge .rb_ccpd
    mov al, [rsi+rcx]
    mov [rdi+r15], al
    inc r15
    inc rcx
    jmp .rb_ccp
.rb_ccpd:
    add rbx, r8
    add rbx, 2
    jmp .rb_chunk
.rb_cdone:
    lea r8, [rip+hx_dechunk]
.rb_region:
    mov [rip+hx_bodyptr], r8
    mov [rip+hx_bodylen], r15
    mov rax, r15
    inc rax
    shl rax, 3
    mov rdi, rax
    call rt_alloc
    mov rbx, rax
    mov r8, [rip+hx_bodyptr]
    mov r15, [rip+hx_bodylen]
    xor rcx, rcx
    xor r9, r9
.rb_dec:
    cmp rcx, r15
    jge .rb_decd
    movzx rax, byte ptr [r8+rcx]
    cmp rax, 0x80
    jb .rb_draw
    cmp rax, 0xC0
    jb .rb_draw
    cmp rax, 0xE0
    jb .rb_d2
    cmp rax, 0xF0
    jb .rb_d3
    cmp rax, 0xF8
    jb .rb_d4
.rb_draw:
    mov [rbx + r9*8 + 8], rax
    inc rcx
    inc r9
    jmp .rb_dec
.rb_d2:
    lea rdx, [rcx+1]
    cmp rdx, r15
    jge .rb_draw
    movzx r10, byte ptr [r8+rcx+1]
    mov rdx, r10
    and rdx, 0xC0
    cmp rdx, 0x80
    jne .rb_draw
    and rax, 0x1F
    shl rax, 6
    and r10, 0x3F
    or rax, r10
    mov [rbx + r9*8 + 8], rax
    add rcx, 2
    inc r9
    jmp .rb_dec
.rb_d3:
    lea rdx, [rcx+2]
    cmp rdx, r15
    jge .rb_draw
    movzx r10, byte ptr [r8+rcx+1]
    mov rdx, r10
    and rdx, 0xC0
    cmp rdx, 0x80
    jne .rb_draw
    movzx r11, byte ptr [r8+rcx+2]
    mov rdx, r11
    and rdx, 0xC0
    cmp rdx, 0x80
    jne .rb_draw
    and rax, 0x0F
    shl rax, 12
    and r10, 0x3F
    shl r10, 6
    or rax, r10
    and r11, 0x3F
    or rax, r11
    mov [rbx + r9*8 + 8], rax
    add rcx, 3
    inc r9
    jmp .rb_dec
.rb_d4:
    lea rdx, [rcx+3]
    cmp rdx, r15
    jge .rb_draw
    movzx r10, byte ptr [r8+rcx+1]
    mov rdx, r10
    and rdx, 0xC0
    cmp rdx, 0x80
    jne .rb_draw
    movzx r11, byte ptr [r8+rcx+2]
    mov rdx, r11
    and rdx, 0xC0
    cmp rdx, 0x80
    jne .rb_draw
    movzx r13, byte ptr [r8+rcx+3]
    mov rdx, r13
    and rdx, 0xC0
    cmp rdx, 0x80
    jne .rb_draw
    and rax, 0x07
    shl rax, 18
    and r10, 0x3F
    shl r10, 12
    or rax, r10
    and r11, 0x3F
    shl r11, 6
    or rax, r11
    and r13, 0x3F
    or rax, r13
    mov [rbx + r9*8 + 8], rax
    add rcx, 4
    inc r9
    jmp .rb_dec
.rb_decd:
    mov [rbx], r9
    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.section .rodata
hx_sp: .ascii " "
hx_lit_http: .ascii " HTTP/1.1\r\nHost: "
hx_lit_hdrs: .ascii "\r\nUser-Agent: word-tls\r\nConnection: close\r\n"
hx_lit_clen: .ascii "Content-Length: "
hx_crlf: .ascii "\r\n"
hx_crlf2: .ascii "\r\n\r\n"
hx_chunked: .ascii "chunked"
hx_m_get: .ascii "GET"
hx_m_post: .ascii "POST"
hx_m_put: .ascii "PUT"
hx_m_delete: .ascii "DELETE"
hx_m_head: .ascii "HEAD"
.section .bss
hx_host: .space 256
hx_path: .space 2048
hx_req: .space 8192
hx_resp: .space 4194304
hx_dechunk: .space 4194304
hx_numbuf: .space 32
hx_cur: .space 8
hx_scheme: .space 8
hx_port: .space 8
hx_hostlen: .space 8
hx_pathlen: .space 8
hx_method_ptr: .space 8
hx_method_len: .space 8
hx_body: .space 8
hx_bodyptr: .space 8
hx_bodylen: .space 8
.text

"""

class Codegen:
    def __init__(self, program, target='linux'):
        self.program = program
        self.target = target
        self.func_names = {it.name for it in program.items if isinstance(it, Function)}
        self.lines = []
        self.uses_net = False
        self.label_n = 0
        self.literals = []           # list of element-lists
        self.lit_offset = {}         # id(node) -> byte offset in the pool
        self.synth = {}              # text -> Str node, for literals the generator needs (arch, kind)
        self.before = {}             # function name -> before-hook
        self.after = {}              # function name -> after-hook
        self.in_hook = False         # are we generating inside a hook body?
        self.hook_pass = None        # label to jump to when a guard passes

    def emit(self, s=""):
        self.lines.append(s)

    def new_label(self):
        self.label_n += 1
        return f".L{self.label_n}"

    def kind(self, e):
        return static_kind(e, self.func_names)

    # --- string literal pool ---
    def synth_literal(self, text):
        """A literal the generator needs but no Str node in the source provides."""
        if text not in self.synth:
            n = Str([ord(c) for c in text], 0, 0)
            self.intern(n)
            self.synth[text] = n
        return self.synth[text]

    def literal_label(self, text):
        return f"{REGION_BASE + self.lit_offset[id(self.synth[text])]}"

    def intern(self, node):
        off = 0
        for prev in self.literals:
            off += (len(prev) + 1) * 8
        self.literals.append(node.elems)
        self.lit_offset[id(node)] = off

    def prepass_literals(self, node):
        if isinstance(node, Str):
            self.intern(node)
        elif isinstance(node, Binary):
            self.prepass_literals(node.left); self.prepass_literals(node.right)
        elif isinstance(node, Unary):
            self.prepass_literals(node.operand)
        elif isinstance(node, Index):
            self.prepass_literals(node.base); self.prepass_literals(node.index)
        elif isinstance(node, Call):
            for a in node.args:
                self.prepass_literals(a)
        elif isinstance(node, MapLit):
            for k in node.keys: self.prepass_literals(k)
            for v in node.vals: self.prepass_literals(v)
        elif isinstance(node, Decl):
            self.prepass_literals(node.expr)
        elif isinstance(node, Assign):
            self.prepass_literals(node.target); self.prepass_literals(node.expr)
        elif isinstance(node, If):
            self.prepass_literals(node.cond)
            for s in node.then: self.prepass_literals(s)
            for s in (node.orelse or []): self.prepass_literals(s)
        elif isinstance(node, Loop):
            if node.cond is not None: self.prepass_literals(node.cond)
            for s in node.body: self.prepass_literals(s)
        elif isinstance(node, Return):
            if node.expr is not None: self.prepass_literals(node.expr)
        elif isinstance(node, ExprStmt):
            self.prepass_literals(node.call)
        elif isinstance(node, (Function,)):
            for s in node.body: self.prepass_literals(s)

    # --- local variable layout ---
    def collect_locals(self, stmts, acc):
        for s in stmts:
            if isinstance(s, Decl):
                if s.name not in acc:
                    acc.append(s.name)
            elif isinstance(s, Assign) and isinstance(s.target, Name):
                # `=` declares on its first use of a name (spec 5), and the slot
                # is the function's, not the block's (spec 5.1), so a name first
                # assigned inside an `if` is still there after it.
                if s.target.ident not in acc:
                    acc.append(s.target.ident)
            elif isinstance(s, If):
                self.collect_locals(s.then, acc)
                self.collect_locals(s.orelse or [], acc)
            elif isinstance(s, Loop):
                self.collect_locals(s.body, acc)
        return acc

    # ============ top-level driver ============
    def generate(self):
        top_stmts = [it for it in self.program.items
                     if not isinstance(it, (Function, Hook))]
        for it in self.program.items:
            if isinstance(it, Hook):
                kind = it.targets[0][1]
                for (fname, _) in it.targets:
                    (self.before if kind == "before" else self.after)[fname] = it
                for s in it.body:
                    self.prepass_literals(s)
            else:
                self.prepass_literals(it)
        for _t in ("x86-64", "number", "text", "map"):
            self.synth_literal(_t)

        if self.target == 'windows':
            self.emit(".intel_syntax noprefix")
            self.emit(".global mainentry")
            self.emit(".text")
            self.emit("mainentry:")
            self.emit("    and rsp, -16")
            self.emit("    sub rsp, 32")
            self.emit("    call rt_init")
            self.emit("    call fn__toplevel")
            self.emit("    mov ecx, eax")
            self.emit("    and ecx, 255")
            self.emit("    call qword ptr [rip+__imp_ExitProcess]")
            import os as _os
            _here = _os.path.dirname(_os.path.abspath(__file__))
            _wrt = _os.path.join(_here, "word_runtime_win.s")
            if not _os.path.exists(_wrt):
                _wrt = _os.path.join(_here, "..", "runtime", "word_runtime_win.s")
            self.emit(open(_wrt).read().rstrip("\n"))
        else:
            self.emit(".intel_syntax noprefix")
            self.emit(".global _start")
            self.emit(".text")
            self.emit("_start:")
            self.emit("    call rt_init")
            self.emit("    call fn__toplevel")
            self.emit("    mov rdi, rax")
            self.emit("    and rdi, 255")
            self.emit("    mov rax, 60")
            self.emit("    syscall")
            rt = (RUNTIME.replace("{BASE}", hex(REGION_BASE))
                         .replace("{SPAN}", hex(REGION_SPAN))
                         .replace("{END}", hex(REGION_END)))
            for _n, _t in ERR.items():
                rt = rt.replace("{LEN_" + _n.upper() + "}", str(len(_t)))
            self.emit(rt)

        for it in self.program.items:
            if isinstance(it, Function):
                self.gen_function(it.name, it.params, it.body)
        self.gen_function("_toplevel", [], top_stmts)

        if self.uses_net:
            if self.target == 'windows':
                self.emit(HTTPX.replace("\n    syscall\n", "\n    call w_syscall\n"))
            else:
                self.emit(HTTPX)
        self.gen_data()
        return "\n".join(self.lines) + "\n"

    def gen_function(self, name, params, body):
        # A function with contracts becomes two symbols: fn_NAME.body (the raw
        # function) and fn_NAME (a wrapper running the guards). Normal calls go to
        # fn_NAME. Calls made from inside a hook body go to fn_NAME.body and skip
        # the guards, so a guard that calls its own function can't recurse forever.
        #
        # A word identifier can't contain a dot, so fn_NAME.body can never collide
        # with another user function's label. `_body` could, and did: word.w
        # defines both `pin_scan` and `pin_scan_body`, so `fn_pin_scan_body` was
        # emitted twice and every call to pin_scan_body ran pin_scan instead.
        if name in self.before or name in self.after:
            self.emit_body([f"fn_{name}.body"], params, body)
            self.emit_wrapper(name, params)
        else:
            self.emit_body([f"fn_{name}", f"fn_{name}.body"], params, body)

    def emit_body(self, labels, params, body):
        env = {}
        for i, p in enumerate(params):
            env[p] = f"[rbp + {16 + 8*i}]"
        # A name that's already a parameter isn't a new local: `lst = nl` inside
        # `f(lst)` rebinds the parameter. A second slot shadowing it would make
        # every earlier read of `lst` see garbage.
        locals_ = [ln for ln in self.collect_locals(body, []) if ln not in params]
        for i, ln in enumerate(locals_):
            env[ln] = f"[rbp - {8*(i+1)}]"
        frame = 8 * len(locals_)
        if frame % 16 != 0:
            frame += 8
        self.env = env
        for lbl in labels:
            self.emit(f"{lbl}:")
        self.emit("    push rbp")
        self.emit("    mov rbp, rsp")
        if frame:
            self.emit(f"    sub rsp, {frame}")
        for s in body:
            self.gen_stmt(s)
        self.emit("    xor rax, rax")        # fall off the end -> 0
        self.emit("    mov rsp, rbp")
        self.emit("    pop rbp")
        self.emit("    ret")

    def emit_wrapper(self, name, params):
        before = self.before.get(name)
        after = self.after.get(name)
        before_locals = [ln for ln in self.collect_locals(before.body, [])
                         if ln not in params] if before else []
        after_locals = [ln for ln in self.collect_locals(after.body, [])
                        if ln not in params and ln != "result"] if after else []
        frame = 8 * (1 + len(before_locals) + len(after_locals))   # +1 = saved result
        if frame % 16 != 0:
            frame += 8
        base_env = {p: f"[rbp + {16 + 8*i}]" for i, p in enumerate(params)}
        result_off = 8
        off = 16
        before_env = dict(base_env)
        for ln in before_locals:
            before_env[ln] = f"[rbp - {off}]"; off += 8
        after_env = dict(base_env)
        after_env["result"] = f"[rbp - {result_off}]"
        for ln in after_locals:
            after_env[ln] = f"[rbp - {off}]"; off += 8

        self.emit(f"fn_{name}:")
        self.emit("    push rbp")
        self.emit("    mov rbp, rsp")
        if frame:
            self.emit(f"    sub rsp, {frame}")
        if before:
            self.env = before_env
            pass_lbl = self.new_label()
            self.in_hook = True
            self.hook_pass = pass_lbl
            for s in before.body:
                self.gen_stmt(s)
            self.emit(f"{pass_lbl}:")         # reaching here = guard passed
            self.in_hook = False
        for i in reversed(range(len(params))):
            self.emit(f"    mov rax, [rbp + {16 + 8*i}]")
            self.emit("    push rax")
        self.emit(f"    call fn_{name}.body")
        if params:
            self.emit(f"    add rsp, {8*len(params)}")
        self.emit(f"    mov [rbp - {result_off}], rax")
        if after:
            self.env = after_env
            pass_lbl = self.new_label()
            self.in_hook = True
            self.hook_pass = pass_lbl
            for s in after.body:
                self.gen_stmt(s)
            self.emit(f"{pass_lbl}:")
            self.in_hook = False
        self.emit(f"    mov rax, [rbp - {result_off}]")
        self.emit("    mov rsp, rbp")
        self.emit("    pop rbp")
        self.emit("    ret")

    # ============ statements ============
    def gen_stmt(self, s):
        if getattr(s, "line", 0):
            self.emit(f"    mov qword ptr [rip+cur_line], {s.line}")
        if isinstance(s, Decl):
            self.gen_expr(s.expr)
            self.emit(f"    mov {self.env[s.name]}, rax")
        elif isinstance(s, Assign):
            if isinstance(s.target, Name):
                self.gen_expr(s.expr)
                self.emit(f"    mov {self.env[s.target.ident]}, rax")
            else:
                self.gen_index_store(s.target, s.expr)
        elif isinstance(s, If):
            self.gen_if(s)
        elif isinstance(s, Loop):
            self.gen_loop(s)
        elif isinstance(s, Return):
            if self.in_hook:
                # a hook's return is a pass/fail signal: falsy -> contract fault
                self.gen_expr(s.expr)
                self.emit("    cmp rax, 0")
                self.emit("    je rt_contract")
                self.emit(f"    jmp {self.hook_pass}")
            else:
                if s.expr is not None:
                    self.gen_expr(s.expr)
                else:
                    self.emit("    xor rax, rax")
                self.emit("    mov rsp, rbp")
                self.emit("    pop rbp")
                self.emit("    ret")
        elif isinstance(s, Break):
            self.emit(f"    jmp {self.break_target}")
        elif isinstance(s, ExprStmt):
            self.gen_expr(s.call)

    def gen_if(self, s):
        else_l = self.new_label()
        end_l = self.new_label()
        self.gen_expr(s.cond)
        self.emit("    cmp rax, 0")
        self.emit(f"    je {else_l}")
        for st in s.then:
            self.gen_stmt(st)
        self.emit(f"    jmp {end_l}")
        self.emit(f"{else_l}:")
        for st in (s.orelse or []):
            self.gen_stmt(st)
        self.emit(f"{end_l}:")

    def gen_loop(self, s):
        top = self.new_label()
        end = self.new_label()
        prev_break = getattr(self, "break_target", None)
        self.break_target = end
        self.emit(f"{top}:")
        if s.cond is not None:
            self.gen_expr(s.cond)
            self.emit("    cmp rax, 0")
            self.emit(f"    je {end}")
        for st in s.body:
            self.gen_stmt(st)
        self.emit(f"    jmp {top}")
        self.emit(f"{end}:")
        self.break_target = prev_break

    def gen_index_store(self, target, value_expr):
        # target = Index(base, index); evaluate value, base, index
        self.gen_expr(value_expr)
        self.emit("    push rax")            # value
        self.gen_expr(target.base)
        self.emit("    push rax")            # base
        self.gen_expr(target.index)
        self.emit("    mov rcx, rax")        # index
        self.emit("    pop rax")             # base
        self.emit("    pop rdx")             # value
        # m[k] = v against a[i] = v, told apart by the key the same way the load is.
        ik = self.kind(target.index)
        smap = None
        if ik == REGION:
            self.emit("    mov rdi, rax"); self.emit("    mov rsi, rcx")
            self.emit("    call rt_map_set")
            return
        if ik == UNKNOWN:
            smap, sdone = self.new_label(), self.new_label()
            self.emit("    push rax"); self.emit("    push rdx")
            self.emit("    mov rdi, rcx")
            self.emit("    call rt_isreg")
            self.emit("    test rax, rax")
            self.emit("    pop rdx"); self.emit("    pop rax")
            self.emit(f"    jnz {smap}")
            self.deferred_map_store = (smap, sdone)
        if self.kind(target.base) == UNKNOWN:
            self.emit_regcheck("rax")
        # write-to-literal check
        self.emit("    mov r10, [rip+litpool_top]")
        self.emit("    cmp rax, r10")
        self.emit("    jb rt_wrlit")
        # bounds check
        self.emit("    mov r11, [rax]")
        self.emit("    cmp rcx, 0")
        self.emit("    jl rt_bounds")
        self.emit("    cmp rcx, r11")
        self.emit("    jge rt_bounds")
        self.emit("    mov [rax + rcx*8 + 8], rdx")
        if getattr(self, "deferred_map_store", None):
            smap, sdone = self.deferred_map_store
            self.deferred_map_store = None
            self.emit(f"    jmp {sdone}")
            self.emit(f"{smap}:")
            self.emit("    mov rdi, rax"); self.emit("    mov rsi, rcx")
            self.emit("    call rt_map_set")
            self.emit(f"{sdone}:")

    # ============ expressions (result in rax) ============
    def gen_expr(self, e):
        if isinstance(e, Num):
            self.emit(f"    movabs rax, {e.value}")
        elif isinstance(e, Singleton):
            self.gen_singleton(e)
        elif isinstance(e, Str):
            self.emit(f"    movabs rax, {REGION_BASE + self.lit_offset[id(e)]}")
        elif isinstance(e, Name):
            self.emit(f"    mov rax, {self.env[e.ident]}")
        elif isinstance(e, Unary):
            self.gen_unary(e)
        elif isinstance(e, Binary):
            self.gen_binary(e)
        elif isinstance(e, MapLit):
            self.emit("    call rt_map_new")
            for k, v in zip(e.keys, e.vals):
                self.emit("    push rax")
                self.gen_expr(v); self.emit("    push rax")
                self.gen_expr(k); self.emit("    mov rsi, rax")
                self.emit("    pop rdx")
                self.emit("    pop rdi")
                self.emit("    push rdi")
                self.emit("    call rt_map_set")
                self.emit("    pop rax")
        elif isinstance(e, Index):
            self.gen_index_load(e)
        elif isinstance(e, Call):
            self.gen_call(e)
        else:
            raise CodegenError(f"cannot generate {type(e).__name__}", 0, 0)

    def gen_singleton(self, e):
        # `true` and `false` are 1 and 0 here. The shipped compiler gives all
        # four singletons their own tagged words, so `false == 0` is false and
        # `1 + true` faults. The seed's untagged model has no room for that, and
        # compiler/word.w never needs it: it only tests a boolean for truth,
        # negates it, or returns it. It never writes `null` or `none`, so the
        # seed refuses them instead of modelling them wrongly.
        if e.word == "true":
            self.emit("    movabs rax, 1")
        elif e.word == "false":
            self.emit("    movabs rax, 0")
        else:
            raise CodegenError(
                f"the bootstrap seed does not implement {e.word!r} "
                "(it models true and false as 1 and 0; compiler/word.w uses neither "
                "null nor none)", e.line, e.col)

    def emit_numcheck(self, reg):
        # fault if `reg` holds a region where a number is required
        self.emit(f"    mov r10, {reg}")
        self.emit(f"    movabs r11, {hex(REGION_BASE)}")
        self.emit("    sub r10, r11")
        self.emit(f"    movabs r11, {hex(REGION_SPAN)}")
        self.emit("    cmp r10, r11")
        self.emit("    jb rt_numfault")

    def emit_divguard(self):
        self.emit("    test rcx, rcx")
        self.emit("    jz rt_div0")
        lbl = self.new_label()
        self.emit(f"    movabs r11, {hex(1 << 63)}")
        self.emit("    cmp rax, r11")
        self.emit(f"    jne {lbl}")
        self.emit("    cmp rcx, -1")
        self.emit("    je rt_overflow")
        self.emit(f"{lbl}:")

    def emit_regcheck(self, reg):
        # fault if `reg` does NOT hold a region where one is required
        self.emit(f"    mov r10, {reg}")
        self.emit(f"    movabs r11, {hex(REGION_BASE)}")
        self.emit("    sub r10, r11")
        self.emit(f"    movabs r11, {hex(REGION_SPAN)}")
        self.emit("    cmp r10, r11")
        self.emit("    jae rt_regfault")

    def gen_unary(self, e):
        self.gen_expr(e.operand)
        if e.op == "-":
            if self.kind(e.operand) == UNKNOWN:
                self.emit_numcheck("rax")
            self.emit("    neg rax")
        elif e.op == "~":
            if self.kind(e.operand) == UNKNOWN:
                self.emit_numcheck("rax")
            self.emit("    not rax")
        elif e.op == "!":
            self.emit("    cmp rax, 0")
            self.emit("    sete al")
            self.emit("    movzx rax, al")

    def gen_binary(self, e):
        op = e.op
        if op == "&&" or op == "||":
            return self.gen_logic(e)
        if op == ".":
            self.gen_expr(e.left); self.emit("    push rax")
            self.gen_expr(e.right); self.emit("    mov rsi, rax")
            self.emit("    pop rdi")
            self.emit("    call rt_join")
            return
        if op in ("==", "!=", "<", "<=", ">", ">="):
            return self.gen_compare(e)
        # numeric binary: left in rax, right in rcx
        self.gen_expr(e.left); self.emit("    push rax")
        self.gen_expr(e.right); self.emit("    mov rcx, rax")
        self.emit("    pop rax")
        if self.kind(e.left) == UNKNOWN:
            self.emit_numcheck("rax")
        if self.kind(e.right) == UNKNOWN:
            self.emit_numcheck("rcx")
        if op == "+":
            self.emit("    add rax, rcx")
        elif op == "-":
            self.emit("    sub rax, rcx")
        elif op == "*":
            self.emit("    imul rax, rcx")
        elif op == "/":
            self.emit_divguard(); self.emit("    cqo"); self.emit("    idiv rcx")
        elif op == "%":
            self.emit_divguard(); self.emit("    cqo"); self.emit("    idiv rcx")
            self.emit("    mov rax, rdx")
        elif op == "&":
            self.emit("    and rax, rcx")
        elif op == "|":
            self.emit("    or rax, rcx")
        elif op == "^":
            self.emit("    xor rax, rcx")
        elif op in ("<<", ">>"):
            self.emit("    cmp rcx, 63"); self.emit("    ja rt_shift")
            self.emit("    sal rax, cl" if op == "<<" else "    sar rax, cl")

    def gen_compare(self, e):
        self.gen_expr(e.left); self.emit("    push rax")
        self.gen_expr(e.right); self.emit("    mov rsi, rax")
        self.emit("    pop rdi")
        if e.op == "==":
            self.emit("    call rt_eq")
        elif e.op == "!=":
            self.emit("    call rt_eq"); self.emit("    xor rax, 1")
        else:
            self.emit("    call rt_order")
            setcc = {"<": "setl", "<=": "setle", ">": "setg", ">=": "setge"}[e.op]
            self.emit("    cmp rax, 0")
            self.emit(f"    {setcc} al")
            self.emit("    movzx rax, al")

    def gen_logic(self, e):
        end = self.new_label()
        short = self.new_label()
        self.gen_expr(e.left)
        self.emit("    cmp rax, 0")
        if e.op == "&&":
            self.emit(f"    je {short}")     # left false -> whole is 0
            self.gen_expr(e.right)
            self.emit("    cmp rax, 0")
            self.emit(f"    je {short}")
            self.emit("    mov rax, 1")
            self.emit(f"    jmp {end}")
            self.emit(f"{short}:")
            self.emit("    xor rax, rax")
        else:  # ||
            self.emit(f"    jne {short}")     # left true -> whole is 1
            self.gen_expr(e.right)
            self.emit("    cmp rax, 0")
            self.emit(f"    jne {short}")
            self.emit("    xor rax, rax")
            self.emit(f"    jmp {end}")
            self.emit(f"{short}:")
            self.emit("    mov rax, 1")
        self.emit(f"{end}:")

    def gen_index_load(self, e):
        self.gen_expr(e.base); self.emit("    push rax")
        self.gen_expr(e.index); self.emit("    mov rcx, rax")
        self.emit("    pop rax")
        # m[k] and a[i] are the same syntax, told apart by the key: a map key is
        # text, a region index is a number (spec 3.7). So the dispatch is exact
        # and needs no marker on the map. Where the analyzer already knows the
        # index is a number, nothing extra is emitted.
        ik = self.kind(e.index)
        if ik == REGION:
            self.emit("    mov rdi, rax"); self.emit("    mov rsi, rcx")
            self.emit("    call rt_map_get")
            return
        done = None
        if ik == UNKNOWN:
            lmap, done = self.new_label(), self.new_label()
            self.emit("    push rax")
            self.emit("    mov rdi, rcx")
            self.emit("    call rt_isreg")
            self.emit("    test rax, rax")
            self.emit("    pop rax")            # pop leaves the flags alone
            self.emit(f"    jnz {lmap}")
            self.deferred_map_load = (lmap, done)
        if self.kind(e.base) == UNKNOWN:
            self.emit_regcheck("rax")
        self.emit("    mov r11, [rax]")
        self.emit("    cmp rcx, 0")
        self.emit("    jl rt_bounds")
        self.emit("    cmp rcx, r11")
        self.emit("    jge rt_bounds")
        self.emit("    mov rax, [rax + rcx*8 + 8]")
        if getattr(self, "deferred_map_load", None):
            lmap, done = self.deferred_map_load
            self.deferred_map_load = None
            self.emit(f"    jmp {done}")
            self.emit(f"{lmap}:")
            self.emit("    mov rdi, rax"); self.emit("    mov rsi, rcx")
            self.emit("    call rt_map_get")
            self.emit(f"{done}:")

    def gen_call(self, e):
        name = e.name
        if name in self.func_names:
            for a in reversed(e.args):
                self.gen_expr(a)
                self.emit("    push rax")
            target = f"fn_{name}.body" if self.in_hook else f"fn_{name}"
            self.emit(f"    call {target}")
            if e.args:
                self.emit(f"    add rsp, {8*len(e.args)}")
            return
        if name == "out":
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_out")
            return
        if name == "len":
            self.gen_expr(e.args[0])
            if self.kind(e.args[0]) == UNKNOWN:
                self.emit_regcheck("rax")
            self.emit("    mov rax, [rax]")
            return
        if name == "in":
            self.emit("    call rt_readline")
            return
        if name == "argument":
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_arg")
            return
        if name == "numeric":
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_isreg")
            self.emit("    xor rax, 1")
            return
        if name == "eof":
            self.emit("    call rt_eof")
            return
        if name == "slice":
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    push rax")
            self.gen_expr(e.args[2]); self.emit("    mov rdx, rax")
            self.emit("    pop rsi")
            self.emit("    pop rdi")
            self.emit("    call rt_slice")
            return
        if name == "read":
            self.gen_expr(e.args[0]); self.emit("    mov rdi, rax")
            self.emit("    call rt_read")
            return
        if name == "write":
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    mov rsi, rax")
            self.emit("    pop rdi")
            self.emit("    xor rdx, rdx")
            self.emit("    call rt_writef")
            return
        if name == "append":
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    mov rsi, rax")
            self.emit("    pop rdi")
            self.emit("    mov rdx, 1")
            self.emit("    call rt_writef")
            return
        if name == "asmput":
            self.gen_expr(e.args[0]); self.emit("    mov rdi, rax")
            self.emit("    call rt_asmput")
            return
        if name == "asmtake":
            self.emit("    call rt_asmtake")
            return
        if name == "writex":
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    mov rsi, rax")
            self.emit("    pop rdi")
            self.emit("    call rt_writex")
            return
        if name == "exec":
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    mov rsi, rax")
            self.emit("    pop rdi")
            self.emit("    call rt_exec")
            return
        if name in ("get", "post", "put", "delete", "head"):
            self.uses_net = True
            _m = {"get": ("hx_m_get", 3, False), "post": ("hx_m_post", 4, True),
                  "put": ("hx_m_put", 3, True), "delete": ("hx_m_delete", 6, False),
                  "head": ("hx_m_head", 4, False)}[name]
            _lbl, _mlen, _body = _m
            self.gen_expr(e.args[0]); self.emit("    push rax")
            if _body:
                self.gen_expr(e.args[1]); self.emit("    mov rcx, rax")
            else:
                self.emit("    xor rcx, rcx")
            self.emit("    pop rdi")
            self.emit(f"    lea rsi, [rip+{_lbl}]")
            self.emit(f"    mov rdx, {_mlen}")
            self.emit("    call rt_httpx")
            return
        if name == "mark":
            self.emit("    mov rax, [rip+arena_ptr]")
            return
        if name == "reset":
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_reset")
            return
        if name == "args":
            self.emit("    call rt_args")
            return
        if name == "env":
            self.gen_expr(e.args[0]); self.emit("    mov rdi, rax")
            self.emit("    call rt_env")
            return
        if name == "random":
            self.emit("    call rt_random")
            return
        if name == "dir":
            self.gen_expr(e.args[0]); self.emit("    mov rdi, rax")
            self.emit("    call rt_dir")
            return
        if name == "kind":
            # The seed has one region representation and no none, so this
            # answers "number", "map" or "text", never "array", "bytes" or
            # "none". word.w's code compares kind(x) only with "number" and
            # "none". The "none" tests catch errors such as a failed read()
            # (which is 0 here, a number), and the bootstrap build doesn't run
            # into any of those errors.
            lnum, lmap, ldone = self.new_label(), self.new_label(), self.new_label()
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_isreg")
            self.emit("    test rax, rax")
            self.emit(f"    jz {lnum}")
            self.emit("    cmp qword ptr [rdi], 2")
            self.emit(f"    jne {ldone}_t")
            self.emit("    mov r10, [rdi + 16]")
            self.emit("    cmp r10, rdi")
            self.emit(f"    je {lmap}")
            self.emit(f"{ldone}_t:")
            self.emit(f"    movabs rax, {self.literal_label('text')}")
            self.emit(f"    jmp {ldone}")
            self.emit(f"{lmap}:")
            self.emit(f"    movabs rax, {self.literal_label('map')}")
            self.emit(f"    jmp {ldone}")
            self.emit(f"{lnum}:")
            self.emit(f"    movabs rax, {self.literal_label('number')}")
            self.emit(f"{ldone}:")
            return
        if name == "has":
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    mov rsi, rax")
            self.emit("    pop rdi")
            self.emit("    call rt_map_has")
            return
        if name in ("text", "bytes"):
            # text(n) is array(n) without the JSON-array mark, which this seed
            # doesn't have: it only compiles compiler/word.w, and word.w renders
            # no maps.
            #
            # bytes(n) is the same allocation. A byte-backed region differs only
            # in its size and in what a writer does with it, and every writer
            # here already takes the low byte of each element (rt_writex stores
            # `dl`). So a word-backed stand-in behaves the same and uses 8x the
            # memory, which is cheaper than carrying a second region
            # representation through the whole code generator.
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_newreg")
            return
        if name == "copy":
            # copy(p) / copy(p, start) / copy(p, start, end): one builtin, three
            # shapes. rt_slice takes a COUNT, while copy's third argument is an
            # END, so the subtraction happens here.
            if len(e.args) == 1:
                self.gen_expr(e.args[0])
                self.emit("    mov rdi, rax")
                self.emit_regcheck("rdi")
                # A map box is a 2-element region whose second element points
                # at the box itself. No ordinary region has that shape, and the
                # test needs no immediate the seed assembler might not encode.
                # The length is checked first so the second read is in bounds.
                nm, dn = self.new_label(), self.new_label()
                self.emit("    cmp qword ptr [rdi], 2")
                self.emit(f"    jne {nm}")
                self.emit("    mov r10, [rdi + 16]")
                self.emit("    cmp r10, rdi")
                self.emit(f"    jne {nm}")
                # CALL, not a tail jump: this sits inside a live frame, so a
                # jump would leave rt_map_copy's `ret` to pop a saved register
                # instead of a return address.
                self.emit("    call rt_map_copy")
                self.emit(f"    jmp {dn}")
                self.emit(f"{nm}:")
                self.emit("    xor rsi, rsi")
                self.emit("    mov rdx, [rdi]")
                self.emit("    call rt_slice")
                self.emit(f"{dn}:")
                return
            self.gen_expr(e.args[0]); self.emit("    push rax")
            self.gen_expr(e.args[1]); self.emit("    push rax")
            if len(e.args) == 3:
                self.gen_expr(e.args[2]); self.emit("    mov rdx, rax")
                self.emit("    pop rsi")
                self.emit("    sub rdx, rsi")          # end -> count
            else:
                self.emit("    pop rsi")
                self.emit("    mov rdx, [rsp]")
                self.emit("    mov rdx, [rdx]")        # len(p)
                self.emit("    sub rdx, rsi")          # to the end
            self.emit("    pop rdi")
            self.emit("    call rt_slice")
            return
        if name == "err":
            # out(), but to fd 2. rt_out and its two helpers read the fd from a
            # global instead of hard-coding 1, so this swaps it around the call.
            self.gen_expr(e.args[0])
            self.emit("    mov qword ptr [rip+out_fd], 2")
            self.emit("    mov rdi, rax")
            self.emit("    call rt_out")
            self.emit("    mov qword ptr [rip+out_fd], 1")
            return
        if name == "arch":
            self.emit(f"    movabs rax, {self.literal_label('x86-64')}")
            return
        if name == "os" or name == "image":
            # The seed only builds Linux x86-64 ELFs: os() is 0 (Linux), and
            # image() has no answer to give (word.w reads /proc/self/exe there).
            self.emit("    xor rax, rax")
            return
        if name == "array":
            self.gen_expr(e.args[0])
            self.emit("    mov rdi, rax")
            self.emit("    call rt_newreg")
            return
        if name in DEFERRED_BUILTINS:
            raise CodegenError(f"{name}() is not yet supported by this compiler", e.line, e.col)
        raise CodegenError(f"unknown call {name!r}", e.line, e.col)

    # ============ data ============
    def gen_data(self):
        self.emit("")
        self.emit(".section .rodata")
        self.emit("litpool:")
        for elems in self.literals:
            vals = ", ".join(str(v) for v in ([len(elems)] + list(elems)))
            self.emit(f"    .quad {vals}" if elems else f"    .quad {len(elems)}")
        self.emit("litpool_end:")
        for _n, _t in ERR.items():
            _esc = _t.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            self.emit(f'err_{_n}: .ascii "{_esc}"')
        self.emit(_gas_ascii("http_a", " HTTP/1.0" + chr(13) + chr(10) + "Host: "))
        self.emit(_gas_ascii("http_b", chr(13) + chr(10) + "Connection: close" + chr(13) + chr(10) + chr(13) + chr(10)))
        self.emit(_gas_ascii("at_line", " at line "))
        self.emit(_gas_ascii("nl_msg", chr(10)))
        self.emit(".section .bss")
        self.emit("    .align 8")
        self.emit("out_fd: .space 8")
        self.emit("dirbuf: .space 32768")   # getdents64 landing area for dir()
        self.emit("dirout: .space 65536")   # the newline-joined names it builds      # 1 for out(), 2 for err(); set in rt_init
        self.emit("arena_ptr: .space 8")
        self.emit("argv_ptr: .space 8")
        self.emit("argc_val: .space 8")
        self.emit("litpool_top: .space 8")
        self.emit("emit_ptr: .space 8")
        self.emit("emit_cap: .space 8")
        self.emit("envp_ptr: .space 8")
        self.emit("execargv: .space 2048")
        self.emit("execbuf: .space 65536")
        self.emit("numscratch: .space 32")
        self.emit("utf8buf: .space 8")
        self.emit("cur_line: .space 8")
        self.emit("inbuf: .space 65536")
        self.emit("inbuf_len: .space 8")
        self.emit("inbuf_pos: .space 8")
        self.emit("in_eof: .space 8")
        self.emit("linebuf: .space 65536")
        self.emit("statbuf: .space 144")   # struct stat; st_size is at +48
        self.emit("pathbuf: .space 4096")
        self.emit("filebuf: .space 1048576")
        self.emit("nethost: .space 256")
        self.emit("netreq: .space 4096")
        self.emit("netsa: .space 16")
        self.emit("dnssa: .space 16")
        self.emit("dnsq: .space 512")
        self.emit("dnsr: .space 512")


def compile_source(src):
    tokens = Lexer(src).tokenize()
    tree = Parser(tokens).parse()
    Analyzer(tree).analyze()
    return Codegen(tree).generate()


SAMPLE = r'''fact(n)
    if n <= 1
        return 1
    return n * fact(n - 1)

i := 1
loop i <= 5
    out(i . "! = " . fact(i) . "\n")
    i = i + 1
'''


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1], encoding="utf-8") as f:
            src, name = f.read(), sys.argv[1]
    else:
        src, name = SAMPLE, "<sample>"
    try:
        print(compile_source(src))
    except (LexError, ParseError, AnalysisError, CodegenError) as e:
        print(f"{name}:{e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
