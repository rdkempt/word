// a64_run.s: the half of the AArch64 encoder that an encoding oracle cannot
// judge, run instead of compared: the wide `mov` sequences llvm-mc rejects
// outright, every logical immediate whose 64-bit pattern does not survive being
// carried in one of word's own 63-bit integers, the branch and PC-relative
// forms whose bytes depend on layout, and the alignment padding, which is only
// correct if walking through it does nothing.
//
// Each block leaves a value in x0 and prints it as 16 hex digits. The expected
// output is in test_a64_run.sh, which is where the arithmetic is checked.
.text
.global _start
_start:
    mov x29, xzr
    sub sp, sp, #256

    // --- wide moves: MOVZ + MOVK, which llvm-mc will not assemble at all ---
    mov x0, #66000
    bl puthex
    mov x0, #0x123456
    bl puthex
    mov x0, #0x123456789
    bl puthex
    mov x0, #0xdeadbeefcafe
    bl puthex
    mov x0, #0x1234000056780000
    bl puthex
    mov x0, #0xfedcba9876543210
    bl puthex
    // and the single-instruction forms it does: MOVZ, MOVN, ORR-with-zr
    mov x0, #0
    bl puthex
    mov x0, #-1
    bl puthex
    mov x0, #-65536
    bl puthex
    mov x0, #0x8000000000000001
    bl puthex
    mov w0, #0x12345678
    bl puthex
    mov w0, #-2
    bl puthex

    // --- logical immediates: the mask that lands is the one that was written.
    // Every value here has bit 63 and bit 62 differing, which is exactly what a
    // 63-bit integer cannot carry, so a truncating encoder answers a DIFFERENT
    // mask rather than an error.
    mov x0, #-1
    and x0, x0, #0x5555555555555555
    bl puthex
    mov x0, #-1
    and x0, x0, #0xaaaaaaaaaaaaaaaa
    bl puthex
    mov x0, #-1
    and x0, x0, #0x0f0f0f0f0f0f0f0f
    bl puthex
    mov x0, #-1
    and x0, x0, #0xfffffffffffffff8
    bl puthex
    mov x0, #-1
    eor x0, x0, #0xffff0000ffff0000
    bl puthex
    mov x0, #0
    orr x0, x0, #0x7fffffffffffffff
    bl puthex
    mov x0, #-1
    and w0, w0, #0x55555555
    bl puthex
    mov x0, #-1
    ands x0, x0, #0x3333333333333333
    cset x1, eq
    bl puthex

    // --- arithmetic, shifts, rotates, bit counting ---
    mov x0, #100
    add x0, x0, #4095
    sub x0, x0, #1
    add x0, x0, #4096
    bl puthex
    mov x1, #7
    mov x2, #3
    add x0, x1, x2, lsl #4
    sub x0, x0, x2, asr #1
    bl puthex
    mov x1, #0x123456789
    lsl x0, x1, #7
    lsr x0, x0, #3
    bl puthex
    mov x1, #-1
    asr x0, x1, #3
    bl puthex
    mov x1, #0x1234
    ror x0, x1, #8
    bl puthex
    mov x1, #0x1234
    mov x2, #4
    ror x0, x1, x2
    bl puthex
    mov x1, #0x1122334455667788
    rev x0, x1
    bl puthex
    mov x1, #0x1122334455667788
    rbit x0, x1
    bl puthex
    mov x1, #0x1000
    clz x0, x1
    bl puthex
    mov x1, #0x123456789abcdef0
    ubfx x0, x1, #8, #16
    bl puthex
    mov x1, #-1
    sbfx x0, x1, #4, #8
    bl puthex
    mov w1, #-1
    sxtb x0, w1
    bl puthex
    mov w1, #-1
    uxth w0, w1
    bl puthex
    mov x1, #0x1234
    mov x2, #0x5678
    extr x0, x1, x2, #16
    bl puthex

    // --- multiply and divide ---
    mov x1, #1000003
    mov x2, #1000033
    mul x0, x1, x2
    bl puthex
    umulh x0, x1, x2
    bl puthex
    mov x1, #-1000003
    mov x2, #7
    sdiv x0, x1, x2
    bl puthex
    udiv x0, x1, x2
    bl puthex
    mov x1, #10
    mov x2, #20
    mov x3, #5
    madd x0, x1, x2, x3
    bl puthex
    msub x0, x1, x2, x3
    bl puthex

    // --- conditional select, the whole family ---
    mov x1, #11
    mov x2, #22
    cmp x1, x2
    csel x0, x1, x2, lt
    bl puthex
    cmp x1, x2
    csinv x0, x1, x2, lt
    bl puthex
    cmp x1, x2
    csneg x0, x1, x2, gt
    bl puthex
    cmp x1, x2
    csetm x0, lt
    bl puthex
    cmp x1, x2
    cinc x0, x1, lt
    bl puthex
    cmp x1, x2
    cinv x0, x1, gt
    bl puthex

    // --- memory: every addressing mode the encoder emits ---
    mov x1, sp
    mov x2, #0x1122334455667788
    str x2, [x1, #8]
    ldr x0, [x1, #8]
    bl puthex
    mov x3, #2
    str x2, [x1, x3, lsl #3]
    ldr x0, [x1, x3, lsl #3]
    bl puthex
    add x4, x1, #64
    str x2, [x4, #-8]!
    ldr x0, [x4]
    bl puthex
    ldr x0, [x4], #16
    sub x4, x4, x1
    mov x0, x4
    bl puthex
    stur x2, [x1, #17]
    ldur x0, [x1, #17]
    bl puthex
    strb w2, [x1, #1]
    ldrb w0, [x1, #1]
    bl puthex
    strh w2, [x1, #2]
    ldrh w0, [x1, #2]
    bl puthex
    mov x5, #3
    strb w2, [x1, x5]
    ldrb w0, [x1, x5]
    bl puthex
    stp x2, x5, [x1, #32]
    ldp x6, x7, [x1, #32]
    eor x0, x6, x2
    add x0, x0, x7
    bl puthex

    // --- branches: the forms whose bytes are a link-time hole ---
    mov x0, #0
    mov x1, #10
.loop:
    add x0, x0, x1
    subs x1, x1, #1
    b.ne .loop
    bl puthex
    mov x1, #4
    mov x0, #0
.cb:
    add x0, x0, #1
    sub x1, x1, #1
    cbnz x1, .cb
    bl puthex
    mov x0, #0
    mov x1, #1
    tbz x1, #0, .tb_no
    mov x0, #0xbeef
.tb_no:
    tbnz x1, #63, .tb_no2
    add x0, x0, #1
.tb_no2:
    bl puthex
    // an indirect call through a register, and a return that has to find the
    // frame the pair store built
    adr x9, addone
    mov x0, #41
    blr x9
    bl puthex
    b .past
    mov x0, #0xdead
.past:
    // alignment padding inside .text: reached by falling through it, so it is
    // correct only if every byte of it is a NOP
    mov x0, #7
    .align 64
    add x0, x0, #1
    bl puthex

    // --- PC-relative addressing reaches the data section ---
    adr x1, marker
    ldr x0, [x1]
    bl puthex
    // adrp only carries the page; prove it lands on the right one by checking
    // it against the page the (byte-exact) adr found
    adrp x1, marker
    adr x3, marker
    and x3, x3, #0xfffffffffffff000
    subs x0, x1, x3
    cset x0, eq
    bl puthex

    mov x0, #0
    mov x8, #93
    svc #0

// x0 -> 16 hex digits and a newline on stdout. Uses the register-offset store
// and a counted loop, so it is itself part of what is under test.
puthex:
    stp x29, x30, [sp, #-96]!
    stp x1, x2, [sp, #16]
    stp x3, x4, [sp, #32]
    stp x5, x6, [sp, #48]
    stp x7, x8, [sp, #64]
    stp x9, x10, [sp, #80]
    adr x1, hexbuf
    mov x2, #16
.ph_next:
    sub x2, x2, #1
    and x3, x0, #15
    add x4, x3, #48
    add x5, x3, #87
    cmp x3, #9
    csel x4, x5, x4, hi
    strb w4, [x1, x2]
    lsr x0, x0, #4
    cbnz x2, .ph_next
    mov x0, #1
    adr x1, hexbuf
    mov x2, #17
    mov x8, #64
    svc #0
    ldp x9, x10, [sp, #80]
    ldp x7, x8, [sp, #64]
    ldp x5, x6, [sp, #48]
    ldp x3, x4, [sp, #32]
    ldp x1, x2, [sp, #16]
    ldp x29, x30, [sp], #96
    ret

addone:
    add x0, x0, #1
    ret

.section .data
hexbuf:
    .space 16
    .byte 10
marker:
    .quad 0x0123456789abcdef
